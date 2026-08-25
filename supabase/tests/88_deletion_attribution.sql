-- LS-57 — deleted_by／還原鎖／family_id 不可變驗收
--
-- 對應 20260825040000_deletion_attribution.sql 的 private.enforce_deletion_attribution()
-- trigger。85_diaries_timeline.sql／86_albums_comments_owner_scope.sql 的角色矩陣段落
-- 已經逐表驗過「owner 軟刪的內容，作者呼叫對應 RPC 還原會拿到 LS027；owner 可以還原
-- 任何一篇／本／則；作者仍可還原自己設下的」——這裡不重複那組矩陣，只補那邊測不到的
-- 事，含 merge-reviewer PR #98 review（R1）B1/B2/B3 三個問題的回歸：
--   1. `deleted_by` 欄位本身的值（不只是「還原有沒有生效」），包含「owner 對已被
--      作者自刪的內容再次移除，deleted_by 必須升級成 owner」（B2）。
--   2. albums 的 hybrid 直接 UPDATE 路徑本身（不透過 RPC）：family_id 不可變、以及
--      直接 UPDATE 清空 owner 設下的 deleted_at 同樣被擋。86_ 的 §B 只測 RPC 路徑。
--   3. 刪除一個「名下有目前仍是軟刪狀態、且 deleted_by 是他」的內容的使用者帳號，
--      trigger 必須放行 FK 的 `on delete set null` RI 動作，不能讓帳號刪不掉（B1，
--      merge-reviewer 實測出的 blocker）。
--   4. `deleted_by` 為 NULL（無論是 migration 套用前就已軟刪除的既有資料，還是
--      移除者帳號後來被刪除）一律視為「移除者不明」，只有 owner 能還原——不是
--      LS-57 初版「作者仍可自行還原」的行為（B3）。
--   5. 已軟刪除的留言仍可用 update_comment 編輯內容（LS-58 既有行為）不能被這支
--      trigger 誤傷——trigger 的推導/還原鎖只在「這次 UPDATE 真的有動 deleted_at」
--      時才介入。
--
-- 角色矩陣沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3。
--
-- 同一交易內連續呼叫 RPC 的已知限制：Postgres 的 `now()` 在同一個交易內是常數
-- （transaction_timestamp 語意）。§1 的 B2 場景需要「先有一筆較早的軟刪紀錄，再讓
-- owner 用不同的時間戳觸發一次新的 UPDATE」，若兩次都在同一交易內呼叫 RPC，
-- `deleted_at` 會拿到同一個 `now()` 值，trigger 的「deleted_at 完全沒變 → 直接放行」
-- 短路會誤判成「沒有觸碰 deleted_at 的一般欄位編輯」而略過推導與升級邏輯（這正是
-- 開發期間第一版手測撞到的假陰性）。修法：STEP1 的「已被作者自刪」狀態改用
-- postgres 身分直接 INSERT 一筆帶著明顯更早時間戳（`now() - interval '1 hour'`）的
-- 既有列（INSERT 不觸發 BEFORE UPDATE trigger），STEP2 owner 再用真正的 RPC 呼叫
-- （拿到當下的 `now()`）—— 兩者的 `deleted_at` 保證不同，才踩得到真正的
-- transition 邏輯，等價於生產環境「兩次呼叫必然是不同交易、`now()` 必然不同」的
-- 情況。
--
-- Mutation 自證（開發期用本機 Supabase CLI 映像實跑 `supabase db reset` +
-- 手動套用/還原單一函式定義驗證，非本檔自動執行）：
--   M1：把 trigger owner 分支的 `new.deleted_by := v_uid` 改成
--       `new.deleted_by := old.deleted_by`（owner 後手移除不再升級歸屬）
--       → §1 STEP2「owner 再次移除後 deleted_by 必須是 owner」斷言變紅（仍是作者），
--         連帶讓 STEP3「作者對已被 owner 接手的內容呼叫還原必須是 LS027」從
--         FAIL（預期拿到 LS027 卻成功了）變成真的成功。
--   M2：拿掉 trigger 裡 `new.family_id is distinct from old.family_id` 那段 raise
--       → §2「建立者直接 UPDATE 把自己的相簿搬到另一個家庭」斷言變紅。
--   M3：把還原鎖的條件 `old.deleted_by is distinct from v_uid` 改成
--       `old.deleted_by is not null and old.deleted_by is distinct from v_uid`
--       （退回 LS-57 初版、NULL 不擋的行為）→ §4「deleted_by 為 NULL 時作者不能
--       自行還原」斷言變紅（作者還原成功）。
--   M4：拿掉 trigger 開頭 B1 那段 RI 放行判定式——**本機實測這條 mutation 不會讓
--       §3 變紅**：B1 判定式與檔頭「deleted_by 的推導規則」段落另一句「deleted_at
--       沒變就直接放行」的判定式在效果上重疊（RI 的 SET NULL 動作定義上不會動
--       deleted_at，後面那句本來就會放行），單獨拿掉 B1 不構成回歸。這不是本檔
--       宣稱錯誤，是誠實記錄這個重疊——保留 B1 判定式的理由（獨立語意標註／
--       不依賴另一句判定式的存在）見 migration 檔頭 B1 段落補記。要讓 §3 真的
--       變紅，必須同時拿掉 B1 判定式**與**「deleted_at 沒變就放行」判定式（等於
--       完全不放行任何「deleted_at 沒變」的 UPDATE），本機也實測過確實會讓 §3
--       撞上 `23503 foreign key violation`。
--   前三個 mutation 各自單獨套用（其餘保持修好的版本）、跑本檔驗證都精準命中對應
--   斷言、其餘斷言正常通過；M4 的驗證方式見上，不是「跑了但沒變紅就代表沒測」。
--
-- ===========================================================================
-- 1. deleted_by 推導：全新軟刪／還原對稱清空／owner 後手移除＝歸屬升級（B2）／
--    升級後作者無法再自行還原（reviewer 原始 STEP1–3 情境，必須在 STEP3 得 LS027）
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
end;
$$;

rollback;

-- reviewer STEP1–3（B2）：獨立一段，用直接 INSERT 模擬 STEP1（見檔頭「同一交易內
-- 連續呼叫」說明），避免 now() 常數陷阱。
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_diary uuid;
  v_deleted_by uuid;
begin
  -- STEP1：作者自刪（模擬既有狀態，直接 INSERT，時間戳刻意早 1 小時）
  set local role postgres;
  insert into public.diaries (family_id, child_id, author_id, body, entry_date, deleted_at, deleted_by)
  values (v_family, v_child, v_author, 'STEP1：作者自刪的日記', current_date,
          now() - interval '1 hour', v_author)
  returning id into v_diary;
  reset role;

  select deleted_by into v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_by is distinct from v_author then
    raise exception 'FAIL SETUP：STEP1 的 deleted_by 應該是作者 %，實際 %', v_author, v_deleted_by;
  end if;

  -- STEP2：owner 對「已被作者自刪」的日記再次移除——這是 B2 要修的核心場景：
  -- deleted_by 必須升級成 owner，不能維持作者不變。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  reset role;

  select deleted_by into v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_by is distinct from v_owner then
    raise exception 'FAIL B2：owner 對已被作者自刪的日記再次移除，deleted_by 應該升級成 owner（%），實際仍是 %——owner 移除等於沒有生效',
      v_owner, v_deleted_by;
  end if;
  raise notice 'ok：owner 對已被作者自刪的日記再次移除，deleted_by 正確升級成 owner（B2）';

  -- STEP3：作者現在呼叫還原，必須拿到 LS027——owner 的後手移除已經生效，不是
  -- no-op，作者不能因為「這是我自己先刪的」就繞過。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, false);
    raise exception 'FAIL STEP3：作者竟然能還原一篇已經被 owner 接手移除的日記——B2 的升級規則沒有真的擋住還原';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  raise notice 'ok：STEP3 作者呼叫還原正確拿到 LS027（owner 的後手移除真的擋住了作者的還原，reviewer STEP1–3 情境已修正）';
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
-- 3.（B1，merge-reviewer PR #98 review blocker）刪除一個「名下有目前仍是軟刪狀態、
--    且 deleted_by 是他」的內容的使用者帳號，必須成功——trigger 要放行 FK 的
--    on delete set null RI 動作，不能讓帳號刪不掉
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner1 uuid := 'a0000000-0000-4000-8000-000000000001';
  v_diary uuid;
  v_deleted_at timestamptz;
  v_deleted_by uuid;
begin
  -- 先確保刪掉 owner1 之後家庭仍有 owner（帳號刪除本身不是本票範圍，這裡只借用
  -- 「先轉移 owner、再刪帳號」這個 MVP 支援的流程作為 B1 的測試前提——reviewer
  -- 原始 repro 特別指出「先轉移 owner 也沒用」，這裡完整重現這個順序）。
  update public.family_members set role = 'owner'
   where family_id = v_family and user_id = 'a0000000-0000-4000-8000-000000000003';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, 'B1：owner1 軟刪的日記', current_date);
  perform public.set_diary_deleted(v_diary, true);
  reset role;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_by is distinct from v_owner1 then
    raise exception 'FAIL SETUP：deleted_by 應該是 owner1（%），實際 %', v_owner1, v_deleted_by;
  end if;

  -- B1：刪除 owner1 的帳號（auth.users，cascade 到 profiles、family_members；
  -- diaries.deleted_by 走 FK 的 on delete set null）——這句 DELETE 之前若沒有 B1
  -- 的放行判定式，會在 RI 動作寫回 diaries.deleted_by 時被這支 trigger 打回
  -- owner1 的舊值，FK 檢查噴 23503（見 migration 檔頭 B1 段落的實測重現）。
  set local role postgres;
  delete from auth.users where id = v_owner1;
  reset role;
  raise notice 'ok：刪除曾軟刪過內容的使用者帳號（已轉移 owner 身分）成功，沒有被 trigger 打死（B1）';

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL B1：owner1 帳號刪除後，這篇日記竟然不是刪除狀態了（deleted_at 變 NULL）——RI 動作不該連帶清掉 deleted_at';
  end if;
  if v_deleted_by is not null then
    raise exception 'FAIL B1：owner1 帳號刪除後，deleted_by 應該被 RI 動作清成 NULL，實際仍是 %', v_deleted_by;
  end if;
  raise notice 'ok：owner1 帳號刪除後，內容仍是已刪除狀態，deleted_by 正確被 RI 動作清成 NULL（B1）';
end;
$$;

rollback;

-- ===========================================================================
-- 4.（B3，merge-reviewer PR #98 review 應修）deleted_by 為 NULL 一律視為「移除者
--    不明」，只有 owner 能還原——不論 NULL 的成因是既有資料還是帳號被刪除
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
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

  -- B3：作者（仍是成員，通過「還是不是這個家庭成員」的基本授權檢查）呼叫還原，
  -- deleted_by 是 NULL——視為「移除者不明」，一律擋下，不是 LS-57 初版「NULL 就
  -- 放行」的行為。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, false);
    raise exception 'FAIL B3：作者竟然能還原一篇 deleted_by 為 NULL 的既有已刪除日記——NULL 應該視為「只有 owner 能還原」';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：被 LS027 擋下的還原呼叫，deleted_at 竟然還是被清掉了';
  end if;
  raise notice 'ok：deleted_by 為 NULL 的既有已刪除日記，作者呼叫還原拿到 LS027（B3：NULL 視為移除者不明，只有 owner 能還原）';

  -- owner 可以還原 deleted_by 為 NULL 的內容，不受影響。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, false);
  reset role;
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：owner 還原 deleted_by 為 NULL 的既有已刪除日記應該成功';
  end if;
  raise notice 'ok：owner 可以還原 deleted_by 為 NULL 的既有已刪除日記（B3）';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 回歸：trigger 的推導／還原鎖不能誤傷「沒有觸碰 deleted_at」的一般欄位編輯
--    ——update_comment 對已軟刪留言的編輯（LS-58 既有行為）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_comment uuid;
  v_body text;
  v_deleted_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_comment := public.create_comment(v_family, 'media', v_media, '原始留言');
  reset role;

  -- owner 軟刪這則留言（作者不是這則留言 deleted_by 的人）。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  reset role;

  -- 作者用 update_comment 編輯內容——這支 RPC 完全不碰 deleted_at（LS-58 定案：
  -- 已軟刪除的留言仍可編輯），trigger 不該因為「old.deleted_by 是 owner、不是我」
  -- 就誤擋這次呼叫（trigger 只在 deleted_at 真的被觸碰時才推導／檢查還原鎖）。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.update_comment(v_comment, '軟刪後仍能改（LS-57 trigger 不該誤傷）');
  reset role;

  select body, deleted_at into v_body, v_deleted_at from public.comments where id = v_comment;
  if v_body <> '軟刪後仍能改（LS-57 trigger 不該誤傷）' then
    raise exception 'FAIL：owner 軟刪的留言，作者用 update_comment 編輯內容應該仍然成功，實際 body=「%」', v_body;
  end if;
  if v_deleted_at is null then
    raise exception 'FAIL：update_comment 不該動到 deleted_at，但軟刪狀態竟然被清掉了';
  end if;
  raise notice 'ok：owner 軟刪的留言，作者仍可用 update_comment 編輯內容且不觸發 LS027（trigger 沒有誤傷沒有觸碰 deleted_at 的一般編輯）——LS-57 R1 回歸';
end;
$$;

rollback;
