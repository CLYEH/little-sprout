-- LS-57 — deleted_by／還原鎖／family_id 不可變驗收
--
-- 對應 20260825040000_deletion_attribution.sql 的 private.enforce_deletion_attribution()
-- trigger。85_diaries_timeline.sql／86_albums_comments_owner_scope.sql 的角色矩陣段落
-- 已經逐表驗過「owner 軟刪的內容，作者呼叫對應 RPC 還原會拿到 LS027；owner 可以還原
-- 任何一篇／本／則；作者仍可還原自己設下的」——這裡不重複那組矩陣，只補三件那邊測不到
-- 的事：
--   1. `deleted_by` 欄位本身的值（不只是「還原有沒有生效」），包含「對已被 owner 刪除的
--      內容重複軟刪，不會把 deleted_by 的歸屬偷天換日成重複軟刪的那個人」這個關鍵防線
--      （見 migration 對 deleted_by 推導規則第三條的說明）。
--   2. albums 的 hybrid 直接 UPDATE 路徑本身（不透過 RPC）：family_id 不可變、以及
--      直接 UPDATE 清空 owner 設下的 deleted_at 同樣被擋。86_ 的 §B 只測 RPC 路徑。
--   3. migration 套用之前就已軟刪除、`deleted_by` 為 NULL 的既有列，維持舊行為
--      （作者仍可自行還原）。
--
-- 角色矩陣沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3。
--
-- Mutation 自證（開發期用本機 Supabase CLI 映像實跑 `supabase db reset` +
-- `supabase/tests/run.sh` 手動驗證，非本檔自動執行）：
--   M1：把 trigger 裡 deleted_by 推導的第三條分支（`else new.deleted_by := old.
--       deleted_by`）改成 `else new.deleted_by := v_uid`（重複軟刪也洗成呼叫者）
--       → §1「owner 刪除後作者重複軟刪，deleted_by 不變」斷言變紅；連帶讓
--       §1 後段「作者對自己剛偷到的 deleted_by 呼叫還原」從 FAIL（預期拿到 LS027
--       卻成功了）變成真的成功——證實這條分支是還原鎖的必要前提，不是多餘的判斷。
--   M2：拿掉 trigger 裡 `new.family_id is distinct from old.family_id` 那段 raise
--       → §2「建立者直接 UPDATE 把自己的相簿搬到另一個家庭」斷言變紅（family_id
--         真的被改掉，且沒有任何錯誤）。
--   M3：把還原鎖的條件從 `new.deleted_at is null`（只管還原方向）改成移除這個條件
--       （兩個方向都擋）→ 不影響本檔任何斷言（本檔沒有測「作者對 owner 刪的重複
--       軟刪」該不該被擋——依 migration 的裁量，這個方向刻意不擋，YAGNI），但會讓
--       §1 的重複軟刪那一步從「成功」變成「LS027」，因為 M1 沒套用的情況下重複軟刪
--       走的也是「觸碰 deleted_at」這個分支——這組 mutation 留給 review 時對照
--       migration 檔頭「還原鎖只管還原方向」那段說明用，不是本檔自動驗證的項目。
--
-- ===========================================================================
-- 1. deleted_by 推導：全新軟刪／還原對稱清空／owner 軟刪後作者重複軟刪不偷走歸屬／
--    偷不到歸屬所以還原鎖持續生效（diaries 代表；albums／comments 走同一支 trigger）
-- ===========================================================================
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_diary uuid;
  v_deleted_at timestamptz;
  v_deleted_by uuid;
  v_deleted_at_2 timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, 'deleted_by 推導測試', current_date);

  -- 全新軟刪：deleted_by 寫成呼叫者本人
  perform public.set_diary_deleted(v_diary, true);
  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_at is null or v_deleted_by is distinct from v_member then
    raise exception 'FAIL：作者自己軟刪後，deleted_by 應該是自己（%），實際 %', v_member, v_deleted_by;
  end if;

  -- 還原：deleted_by 對稱清空成 NULL
  perform public.set_diary_deleted(v_diary, false);
  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_at is not null or v_deleted_by is not null then
    raise exception 'FAIL：還原後 deleted_at／deleted_by 都應該是 NULL，實際 %／%', v_deleted_at, v_deleted_by;
  end if;
  reset role;
  raise notice 'ok：作者自己軟刪／還原時，deleted_by 正確寫入自己／對稱清空';

  -- owner 軟刪：deleted_by 寫成 owner
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  reset role;
  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_at is null or v_deleted_by is distinct from v_owner then
    raise exception 'FAIL：owner 軟刪後，deleted_by 應該是 owner（%），實際 %', v_owner, v_deleted_by;
  end if;

  -- 關鍵防線：作者（仍是成員，通過 RPC 的基本授權檢查）對這篇「owner 已刪除」的日記
  -- 重複呼叫軟刪（p_deleted=true）——這個方向不受還原鎖限制（見 migration），呼叫
  -- 本身會成功（不噴例外），但 deleted_by 必須維持 owner 不變，不能被這次呼叫洗成
  -- 作者自己。時間戳不拿來斷言——`now()` 在同一個交易內是常數
  -- （transaction_timestamp 語意），這個測試檔从頭到尾都在同一個 begin/rollback
  -- 交易裡，兩次呼叫的 deleted_at 本來就會是同一個值，不是判準。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  reset role;
  select deleted_at, deleted_by into v_deleted_at_2, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_at_2 is null then
    raise exception 'FAIL：作者對 owner 軟刪的日記重複軟刪應該成功（仍是刪除狀態），實際 deleted_at 變成 NULL 了';
  end if;
  if v_deleted_by is distinct from v_owner then
    raise exception 'FAIL：作者對 owner 刪除的日記重複軟刪，deleted_by 竟然被洗成 %（應該仍是 owner %）——這是還原鎖能被繞過的漏洞',
      v_deleted_by, v_owner;
  end if;
  raise notice 'ok：作者對 owner 軟刪的日記重複軟刪成功，deleted_by 仍是 owner（歸屬沒有被偷走）';

  -- 承上：既然歸屬沒有被偷走，作者現在呼叫還原仍然會被擋（不是繞過還原鎖之後才擋）。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, false);
    raise exception 'FAIL：作者重複軟刪之後，竟然能還原 owner 軟刪的日記——重複軟刪繞過了還原鎖';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  raise notice 'ok：重複軟刪之後，作者呼叫還原仍然拿到 LS027（歸屬確實沒有被偷走）';
end;
$$;

rollback;

-- ===========================================================================
-- 2. albums：hybrid 直接 UPDATE 路徑（不透過 RPC）——family_id 不可變、
--    清空 owner 設下的 deleted_at 同樣被擋
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'fb000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid;
  v_n int;
  v_family_after uuid;
  v_deleted_at timestamptz;
  v_deleted_by uuid;
begin
  set local role postgres;
  -- 讓作者也是 B 家的 owner，才有「自己也是 contributor 的另一個家庭」可以搬過去
  -- （呼應收斂前 N1 的攻擊前提；LS-57 要驗的正是這條路現在走不通）。
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family_b, v_author, 'owner', true)
  on conflict do nothing;

  insert into public.albums (family_id, title, created_by)
  values (v_family, 'family_id 不可變測試', v_author)
  returning id into v_album;
  reset role;

  -- 建立者直接 UPDATE 想把自己的相簿搬到另一個家庭：LS-57 之前這條路本來走得通
  -- （N1 跨家庭越權 race 的前提），trigger 補上之後一律 42501，family_id 完全不變。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.albums set family_id = v_family_b where id = v_album;
    raise exception 'FAIL：建立者直接 UPDATE 竟然能把自己的相簿搬到別的家庭——family_id 不可變的 trigger 沒有生效';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  select family_id into v_family_after from public.albums where id = v_album;
  if v_family_after <> v_family then
    raise exception 'FAIL：family_id 竟然被改掉了（現在是 %，應該仍是 %）', v_family_after, v_family;
  end if;
  raise notice 'ok：建立者直接 UPDATE 相簿的 family_id 一律 42501，family_id 維持不變——LS-57';

  -- owner 用 RPC 軟刪這本相簿，deleted_by 記成 owner。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  reset role;
  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.albums where id = v_album;
  if v_deleted_at is null or v_deleted_by is distinct from v_owner then
    raise exception 'FAIL：owner 用 RPC 軟刪後，deleted_by 應該是 owner（%），實際 %', v_owner, v_deleted_by;
  end if;

  -- 建立者改用「直接 UPDATE」（不透過 set_album_deleted RPC）清空 deleted_at，
  -- 想繞過 RPC 裡的邏輯還原——86_albums_comments_owner_scope.sql §B 只測過 RPC
  -- 路徑，這裡補的正是 hybrid 模式獨有的第二條寫入路徑，trigger 必須在這裡也擋下。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.albums set deleted_at = null where id = v_album;
    raise exception 'FAIL：建立者直接 UPDATE 竟然能清空 owner 軟刪的 deleted_at——LS-57 的還原鎖只擋了 RPC 路徑，沒擋 hybrid 直接 UPDATE 路徑';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：被 LS027 擋下的直接 UPDATE，deleted_at 竟然還是被清掉了';
  end if;
  raise notice 'ok：建立者直接 UPDATE 清空 owner 軟刪的 deleted_at 同樣拿到 LS027（hybrid 路徑與 RPC 路徑受同一支 trigger 保護）——LS-57';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 既有資料相容性：本欄位新增之前就已軟刪除、deleted_by 為 NULL 的列，
--    維持 LS-57 之前的行為（作者仍可自行還原）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_diary uuid;
  v_deleted_at timestamptz;
begin
  -- 模擬「migration 套用之前就已軟刪除」的既有列：以 postgres 身分直接 INSERT
  -- 一列已經是 deleted_at 非 NULL、deleted_by 是 NULL 的日記——INSERT 不會觸發
  -- BEFORE UPDATE trigger，這正是新欄位對既有資料的真實初始狀態（新增欄位不會
  -- 回填歷史列，見 migration 說明）。
  set local role postgres;
  insert into public.diaries (family_id, child_id, author_id, body, entry_date, deleted_at)
  values (v_family, v_child, v_member, '既有已刪除的日記', current_date, now() - interval '30 days')
  returning id into v_diary;
  reset role;

  if (select deleted_by from public.diaries where id = v_diary) is not null then
    raise exception 'FAIL SETUP：模擬的既有列 deleted_by 應該是 NULL';
  end if;

  -- 作者（仍是成員）呼叫還原：deleted_by 是 NULL，不落入還原鎖的任何一個條件
  -- （`old.deleted_by is not null` 不成立），維持 LS-57 之前的行為，應該成功。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, false);
  reset role;
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：deleted_by 為 NULL 的既有已刪除日記，作者呼叫還原應該成功，實際還是刪除狀態';
  end if;
  raise notice 'ok：deleted_by 為 NULL 的既有已刪除日記，作者仍可自行還原（LS-57 之前的行為，不回溯鎖死既有資料）';
end;
$$;

rollback;
