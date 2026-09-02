-- LS-66（LS-47 後端切片）— children 多寶貝 CRUD RPC、軟刪 30 天可還原、角色矩陣
--
-- 對應 20260825030000_children_write_path_and_soft_delete.sql 的每一項決定。角色矩陣
-- 沿用 00_fixtures.sql 的 A 家：owner=a0..1、member=a0..2、viewer=a0..3、
-- child=2a000000-0000-4000-8000-000000000001（既有 album 4a／diary 5a 已掛在這個孩子
-- 底下，用來驗第 8 段「軟刪不連動」）；非本家庭成員用 B 家 owner（b0..1）代表。
--
-- 每個編號段各自用 begin;/rollback; 包起來（同 85_diaries_timeline.sql 的慣例）：
-- 段內對 family_members／children 的任何暫時性變更（模擬「已離開」「已軟刪超過 30 天」
-- 之類的狀態）不需要手動復原，rollback 會自動還原，不會漂移到後面的段落或後面的測試檔。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 寫入面收斂：children 的直接 INSERT／UPDATE／DELETE 對所有角色都必須被擋
--    （policy + grant 兩層）——DELETE 自 R1 I5 起也收斂，連 owner 都沒有硬刪路徑
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_user text;
begin
  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003',  -- viewer
    'b0000000-0000-4000-8000-000000000001'   -- 非本家庭成員（B 家 owner）
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;

    begin
      insert into public.children (family_id, name, birthday)
      values (v_family, '繞過 RPC 直接建立', date '2024-01-01');
      raise exception 'FAIL：% 竟然可以直接 INSERT children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      update public.children set name = '竄改' where id = v_child;
      raise exception 'FAIL：% 竟然可以直接 UPDATE children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    -- R1 I5：連 owner 也不能直接硬刪——這是本段唯一「連 owner 都該被擋下」的操作
    -- （INSERT/UPDATE 本來就是全員擋，DELETE 現在也是全員擋，不是只擋非 owner）。
    begin
      delete from public.children where id = v_child;
      raise exception 'FAIL：% 竟然可以直接 DELETE children——30 天可還原的保護形同虛設', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 children 的直接 INSERT／UPDATE／DELETE 皆被擋下 (42501)——DELETE 連 owner 也不例外';
end;
$$;

-- 欄位級對帳：連「有沒有任何一欄的 UPDATE/INSERT grant」都要驗過（同 85_ 對 diaries 的
-- 慣例），只驗整表的斷言測不出欄位級 grant 忘了收回。SELECT 的正向對照確保收斂沒有
-- 連帶把讀取路徑也關掉。
do $$
begin
  if has_any_column_privilege('authenticated', 'public.children', 'insert') then
    raise exception 'FAIL：authenticated 還有 children 的 INSERT 授權（表級或任一欄位級）—— create_child 的邊界形同虛設';
  end if;
  if has_any_column_privilege('authenticated', 'public.children', 'update') then
    raise exception 'FAIL：authenticated 還有 children 的 UPDATE 授權（表級或任一欄位級）—— update_child/set_child_deleted 的邊界形同虛設';
  end if;
  if has_table_privilege('authenticated', 'public.children', 'delete') then
    raise exception 'FAIL：authenticated 還有 children 的 DELETE 授權（R1 I5：連 owner 也不該有直接硬刪路徑）';
  end if;
  if not has_table_privilege('authenticated', 'public.children', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 children 的 SELECT grant';
  end if;
  raise notice 'ok：children 授權對帳——INSERT/UPDATE/DELETE 無任何形態的 grant，SELECT 原樣保留（R1 I5：DELETE 收斂）';
end;
$$;

rollback;

-- ===========================================================================
-- 2. create_child：owner／member 能建；viewer／非本家庭成員／未登入不能
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_row public.children%rowtype;
begin
  -- owner 能建
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_child(v_family, 'Owner 建的孩子', date '2025-01-01', 'https://example.test/o.jpg');
  select * into v_row from public.children where id = v_id;
  if v_row.family_id <> v_family or v_row.name <> 'Owner 建的孩子'
     or v_row.birthday <> date '2025-01-01' or v_row.avatar_url <> 'https://example.test/o.jpg'
     or v_row.deleted_at is not null or v_row.deleted_by is not null then
    raise exception 'FAIL：create_child 寫入的欄位與參數不符';
  end if;
  reset role;

  -- member 能建
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_child(v_family, 'Member 建的孩子', date '2025-06-15', null);
  if not exists (select 1 from public.children where id = v_id and family_id = v_family) then
    raise exception 'FAIL：member 建立的孩子檔案沒有正確落地';
  end if;
  reset role;
  raise notice 'ok：owner／member 都能建立孩子檔案，欄位正確落地（avatar_url 可為 NULL）';

  -- viewer 不能建（§3）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_child(v_family, 'viewer 想建的孩子', date '2025-01-01', null);
    raise exception 'FAIL：viewer 竟然可以建立孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員不能建
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_child(v_family, '外人想建的孩子', date '2025-01-01', null);
    raise exception 'FAIL：非本家庭成員竟然可以建立孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法建立孩子檔案 (42501)';

  -- 未登入
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.create_child(v_family, '沒登入', date '2025-01-01', null);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然建得起孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：未登入呼叫 create_child 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 3. update_child：仍是該家庭 owner/member 的成員能編；已離開／已降級不能 (LS042)；
--    已軟刪必須先還原 (LS041)；不存在的孩子 (LS041)
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_child uuid;
  v_row public.children%rowtype;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_child := public.create_child(v_family, '原始名字', date '2025-01-01', null);

  -- member 能編（不必是建立者——children 沒有建立者欄位）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.update_child(v_child, '改過的名字', date '2025-02-02', 'https://example.test/m.jpg');
  select * into v_row from public.children where id = v_child;
  if v_row.name <> '改過的名字' or v_row.birthday <> date '2025-02-02'
     or v_row.avatar_url <> 'https://example.test/m.jpg' then
    raise exception 'FAIL：member 編輯孩子檔案沒有生效';
  end if;
  raise notice 'ok：仍是該家庭 owner/member 的成員可以編輯任何孩子的檔案（不限建立者）';
  reset role;

  -- viewer 不能編
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_child(v_child, 'viewer 想改', date '2025-01-01', null);
    raise exception 'FAIL：viewer 竟然可以編輯孩子檔案';
  exception when sqlstate 'LS042' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員不能編
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_child(v_child, '外人想改', date '2025-01-01', null);
    raise exception 'FAIL：非本家庭成員竟然可以編輯孩子檔案';
  exception when sqlstate 'LS042' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法編輯孩子檔案 (LS042)';

  -- 已離開家庭：完全不在 family_members 裡了 → 不能再編（跟 diaries LS021 F2 同型）
  delete from public.family_members where family_id = v_family and user_id = v_member;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_child(v_child, '離開後想改', date '2025-01-01', null);
    raise exception 'FAIL：已離開家庭的前成員竟然還能編輯孩子檔案';
  exception when sqlstate 'LS042' then
    null;  -- ok
  end;
  reset role;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_member, 'member', true);
  raise notice 'ok：已離開家庭的前成員無法編輯孩子檔案 (LS042)';

  -- 不存在的孩子
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_child(gen_random_uuid(), '不存在', date '2025-01-01', null);
    raise exception 'FAIL：對不存在的孩子 id 呼叫 update_child 竟然沒有出錯';
  exception when sqlstate 'LS041' then
    null;  -- ok
  end;

  -- 已軟刪必須先還原：owner 軟刪之後，member 不能編（即使仍是 owner/member，狀態檢查
  -- 排在授權檢查之後——授權通過後才輪到「這筆是不是已軟刪」）
  perform public.set_child_deleted(v_child, true);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_child(v_child, '軟刪之後還想改', date '2025-01-01', null);
    raise exception 'FAIL：已被軟刪的孩子檔案竟然還能被編輯成功';
  exception when sqlstate 'LS041' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：不存在／已軟刪的孩子檔案呼叫 update_child 皆拿到 LS041';
end;
$$;

rollback;

-- ===========================================================================
-- 4. family_id 不可變 trigger：任何 UPDATE 想搬動 family_id 一律被擋 (42501，
--    LS-57 R2／I1 撤 LS040 對齊 diaries／albums／comments 的裸 42501)，不論呼叫者
--    是誰——這裡直接以資料庫層級的身分（bypass RLS）驗證，證明防線不是只靠 RPC
--    參數沒有 p_family_id，是 trigger 本身真的會擋。
-- ===========================================================================
begin;

do $$
declare
  v_family_a uuid := 'fa000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'fb000000-0000-4000-8000-000000000001';
  v_child uuid;
begin
  insert into public.children (family_id, name, birthday)
  values (v_family_a, '不該被搬家的孩子', date '2025-01-01')
  returning id into v_child;

  begin
    update public.children set family_id = v_family_b where id = v_child;
    raise exception 'FAIL：children 的 family_id 竟然可以被直接改掉——immutable trigger 沒有生效';
  exception when sqlstate '42501' then
    null;  -- ok
  end;

  if (select family_id from public.children where id = v_child) <> v_family_a then
    raise exception 'FAIL：即使拿到 42501，family_id 實際上還是被改動了';
  end if;

  -- 正向對照：改別的欄位（不含 family_id）不受 trigger 影響
  update public.children set name = '換個名字沒問題' where id = v_child;
  if (select name from public.children where id = v_child) <> '換個名字沒問題' then
    raise exception 'FAIL：trigger 誤擋了不含 family_id 的 UPDATE';
  end if;

  raise notice 'ok：children.family_id 建立後不可變 (42501，LS-57 R2／I1 撤 LS040)，其餘欄位的 UPDATE 不受影響';
end;
$$;

rollback;

-- ===========================================================================
-- 5. set_child_deleted：僅 owner；寫 deleted_at／deleted_by；重複軟刪是 no-op
--    （R1 I1/I2，merge-reviewer PR #95 review）；不存在的孩子 (LS041)
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_child uuid;
  v_row public.children%rowtype;
  v_deleted_at_1 timestamptz;
  v_deleted_at_2 timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_child := public.create_child(v_family, '待刪除的孩子', date '2025-01-01', null);
  reset role;

  -- member／viewer／非本家庭成員都不能刪（LS-47 定案：刪除僅 owner，比 create/update 窄）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(v_child, true);
    raise exception 'FAIL：member 竟然可以軟刪孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(v_child, true);
    raise exception 'FAIL：viewer 竟然可以軟刪孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(v_child, true);
    raise exception 'FAIL：非本家庭成員竟然可以軟刪孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：member／viewer／非本家庭成員皆無法軟刪孩子檔案 (42501)——僅 owner';

  -- owner 軟刪：deleted_at／deleted_by 正確寫入
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_child_deleted(v_child, true);
  select * into v_row from public.children where id = v_child;
  if v_row.deleted_at is null or v_row.deleted_by <> v_owner then
    raise exception 'FAIL：軟刪之後 deleted_at/deleted_by 沒有正確寫入（deleted_at=%，deleted_by=%）',
      v_row.deleted_at, v_row.deleted_by;
  end if;

  -- R1 I1／R2 F2 訂正：重複軟刪必須是 no-op——deleted_at 完全不刷新（否則 owner 可以
  -- 無限延後 30 天邊界）。R1 原本的版本在同一個 DO 區塊（同一交易）內用
  -- `pg_sleep()` 想製造時間差，但 `now()` 就是 `transaction_timestamp()`，同一交易
  -- 內是凍結的——`pg_sleep` 完全推不動它，就算把 set_child_deleted 裡的 no-op guard
  -- 拿掉、真的執行了 `set deleted_at = now()`，寫回去的值仍然跟凍結前一樣，斷言永遠
  -- 不會開火（merge-reviewer PR #95 review R2 F2 實測：把軟刪分支改成
  -- `deleted_at = now(), deleted_by = coalesce(v_child.deleted_by, v_uid)`——時鐘退化
  -- 的 bug 回來了，但 deleted_by 仍凍結——這樣的 mutation 下，R1 那個版本的斷言整包
  -- 綠著放行）。修法比照下面第 6 段的既有手法：用 postgres 身分把 deleted_at 直接
  -- 回填成一個明確的過去時間（10 天前，非交易內的相對時間，不受 `now()` 凍結影響），
  -- 再呼叫一次重複軟刪，斷言 deleted_at 沒有被刷新回「現在」。
  reset role;
  update public.children set deleted_at = now() - interval '10 days' where id = v_child;
  select deleted_at into v_deleted_at_1 from public.children where id = v_child;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_child_deleted(v_child, true);
  select deleted_at into v_deleted_at_2 from public.children where id = v_child;
  if v_deleted_at_2 is distinct from v_deleted_at_1 then
    raise exception 'FAIL：重複軟刪之後 deleted_at 被刷新了（原本 10 天前的 %，現在變成 %）——30 天時鐘可以被無限延後',
      v_deleted_at_1, v_deleted_at_2;
  end if;
  reset role;

  -- R1 I1：重複軟刪也不能把 deleted_by 的歸屬洗成別人——promote member 成第二位
  -- owner，用他重複呼叫一次 true，deleted_by 必須維持原本那位 owner，不會變成這位
  -- 第二 owner。這是 mutation 自證的另一半：只驗 deleted_at 凍結測不出 deleted_by
  -- 也凍結，兩者是 set_child_deleted 尾端同一句 UPDATE 的兩個獨立欄位，各自可能漏改。
  update public.family_members set role = 'owner'
   where family_id = v_family and user_id = v_member;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_child_deleted(v_child, true);
  select deleted_by into v_row.deleted_by from public.children where id = v_child;
  if v_row.deleted_by <> v_owner then
    raise exception 'FAIL：第二位 owner 重複軟刪之後 deleted_by 被洗成 %（應維持原本的 %）',
      v_row.deleted_by, v_owner;
  end if;
  reset role;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_member;
  raise notice 'ok：重複軟刪是 no-op——deleted_at 不刷新（30 天時鐘不重設）、deleted_by 不被洗成後來重複呼叫的人';

  -- owner 還原：30 天內，deleted_at／deleted_by 清成 NULL
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_child_deleted(v_child, false);
  select * into v_row from public.children where id = v_child;
  if v_row.deleted_at is not null or v_row.deleted_by is not null then
    raise exception 'FAIL：還原之後 deleted_at/deleted_by 沒有清成 NULL（deleted_at=%，deleted_by=%）',
      v_row.deleted_at, v_row.deleted_by;
  end if;

  -- 還原 idempotent：對本來就是 active 的孩子呼叫 false 是 no-op，不報錯
  perform public.set_child_deleted(v_child, false);
  if (select deleted_at from public.children where id = v_child) is not null then
    raise exception 'FAIL：對 active 的孩子呼叫還原（no-op）之後 deleted_at 竟然非 NULL';
  end if;

  -- R1 I2：還原後再重新軟刪，必須重新計時／重新歸屬（不是繼續凍結）——因為那時
  -- deleted_at 已經是 NULL，屬於「從 active 到已軟刪」的真正轉換。
  perform public.set_child_deleted(v_child, true);
  select * into v_row from public.children where id = v_child;
  if v_row.deleted_at is null or v_row.deleted_by <> v_owner then
    raise exception 'FAIL：還原後重新軟刪，deleted_at/deleted_by 沒有重新寫入（deleted_at=%，deleted_by=%）',
      v_row.deleted_at, v_row.deleted_by;
  end if;
  reset role;
  raise notice 'ok：還原之後再重新軟刪會重新計時、重新歸屬（不是繼續凍結在還原前的狀態）';

  -- 不存在的孩子
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(gen_random_uuid(), true);
    raise exception 'FAIL：對不存在的孩子 id 呼叫 set_child_deleted 竟然沒有出錯';
  exception when sqlstate 'LS041' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：不存在的孩子呼叫 set_child_deleted 拿到 LS041';

  -- 未登入
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(v_child, true);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然能軟刪孩子檔案';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：未登入呼叫 set_child_deleted 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 6. 30 天還原邊界（mutation 自證：正反兩側都要驗過，不能只驗一個方向）——
--    deleted_at 用 postgres 身分直接回填（bypass RLS），模擬「已經是 N 天前軟刪的」
--    起始狀態，不透過 set_child_deleted（那支的軟刪分支只會寫 now()，回填不了過去）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child_29d uuid;
  v_child_30d uuid;
  v_child_31d uuid;
begin
  insert into public.children (family_id, name, birthday, deleted_at, deleted_by)
  values
    (v_family, '29 天前軟刪', date '2025-01-01', now() - interval '29 days', v_owner)
  returning id into v_child_29d;

  insert into public.children (family_id, name, birthday, deleted_at, deleted_by)
  values
    (v_family, '剛好 30 天前軟刪（邊界含）', date '2025-01-01', now() - interval '30 days', v_owner)
  returning id into v_child_30d;

  insert into public.children (family_id, name, birthday, deleted_at, deleted_by)
  values
    (v_family, '31 天前軟刪', date '2025-01-01', now() - interval '31 days', v_owner)
  returning id into v_child_31d;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 29 天前：在 30 天窗口內，還原必須成功
  perform public.set_child_deleted(v_child_29d, false);
  if (select deleted_at from public.children where id = v_child_29d) is not null then
    raise exception 'FAIL：29 天前軟刪的孩子檔案在 30 天窗口內，還原卻沒有成功';
  end if;

  -- 剛好 30 天：判準是「< 30 天前」才擋，等於 30 天不算超過，還原必須成功（邊界含）
  perform public.set_child_deleted(v_child_30d, false);
  if (select deleted_at from public.children where id = v_child_30d) is not null then
    raise exception 'FAIL：剛好 30 天前軟刪的孩子檔案（邊界含）還原卻沒有成功';
  end if;

  -- 31 天前：超過 30 天，還原必須被拒絕 (LS043)，且 deleted_at 維持不變（沒有被還原）
  begin
    perform public.set_child_deleted(v_child_31d, false);
    raise exception 'FAIL：31 天前軟刪的孩子檔案竟然還能被還原（超過 30 天窗口）';
  exception when sqlstate 'LS043' then
    null;  -- ok
  end;
  if (select deleted_at from public.children where id = v_child_31d) is null then
    raise exception 'FAIL：31 天前軟刪的還原嘗試被拒絕，deleted_at 卻變成 NULL 了';
  end if;

  reset role;
  raise notice 'ok：30 天還原邊界正確（29 天／剛好 30 天可還原，31 天被拒絕 LS043 且狀態不變）';
end;
$$;

rollback;

-- ===========================================================================
-- 7. list_children：成員可讀，**不分角色、不分軟刪與否**（R1 I3/I4，merge-reviewer
--    PR #95 review：get_family_timeline 對軟刪孩子的行為不變，若讀取權限收斂成僅
--    owner 可見，member/viewer 會拿到自己解不開的 child_id）——只有「還原」這個
--    動作限 owner，讀取本身對所有角色一視同仁。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_active uuid;
  v_deleted uuid;
  v_count int;
  v_deleted_at timestamptz;
  v_role uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_active := public.create_child(v_family, 'Active 孩子', date '2025-01-01', null);
  v_deleted := public.create_child(v_family, 'Deleted 孩子', date '2025-01-01', null);
  perform public.set_child_deleted(v_deleted, true);
  reset role;

  -- owner／member／viewer：全都看得到 active + 已軟刪兩列，且已軟刪那列的
  -- deleted_at 對每個角色都有值（旗標對所有人可見，不只 owner）
  foreach v_role in array array[v_owner, v_member, v_viewer] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_role, 'role', 'authenticated')::text, true);
    set local role authenticated;

    select count(*) into v_count from public.list_children(v_family)
     where id in (v_active, v_deleted);
    if v_count <> 2 then
      raise exception 'FAIL：% 呼叫 list_children 應看到 2 列（active＋已軟刪），實際 %', v_role, v_count;
    end if;

    select deleted_at into v_deleted_at from public.list_children(v_family) where id = v_deleted;
    if v_deleted_at is null then
      raise exception 'FAIL：% 呼叫 list_children，已軟刪孩子的 deleted_at 旗標竟然是 NULL', v_role;
    end if;

    -- 直接 .from("children").select() 走同一條 RLS，行為必須與 RPC 一致
    select count(*) into v_count from public.children where id = v_deleted;
    if v_count <> 1 then
      raise exception 'FAIL：% 直接 SELECT children 竟然看不到已軟刪的孩子', v_role;
    end if;

    reset role;
  end loop;
  raise notice 'ok：owner／member／viewer 呼叫 list_children（與直接 SELECT children）都看得到 active＋已軟刪兩列，deleted_at 旗標對所有角色可見';

  -- 非本家庭成員：0 列，不報錯（family_ids() 自然過濾，不特殊處理已軟刪與否）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.list_children(v_family);
  if v_count <> 0 then
    raise exception 'FAIL：非本家庭成員呼叫 list_children 竟然回傳非 0 列';
  end if;
  reset role;

  -- 未登入：0 列，不報錯
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select count(*) into v_count from public.list_children(v_family);
  if v_count <> 0 then
    raise exception 'FAIL：未登入呼叫 list_children 竟然回傳非 0 列';
  end if;
  reset role;
  raise notice 'ok：非本家庭成員／未登入呼叫 list_children 皆回傳 0 列，不報錯';

  -- 只有「還原」這個動作限 owner——member/viewer 雖然讀得到已軟刪的孩子，
  -- 呼叫 set_child_deleted 想還原仍然是 42501（角色矩陣已在第 5 段驗過，這裡
  -- 只驗「讀得到」跟「能還原」是兩件事，不會因為放寬讀取就連帶放寬還原）。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_child_deleted(v_deleted, false);
    raise exception 'FAIL：member 讀得到已軟刪的孩子，竟然也能還原他';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：member 讀得到已軟刪的孩子，但還原動作仍然限 owner (42501)——讀取放寬不等於動作放寬';
end;
$$;

rollback;

-- ===========================================================================
-- 8. 軟刪不連動：照片／日記掛在被軟刪孩子底下的標記完全保留
--    （重用 00_fixtures 既有的 album 4a／diary 5a，兩者都經 album_children／
--    diary_children 掛在 child 2a 底下——LS-121：child_id 從 albums/diaries 的
--    單一欄位改成連結表，這裡驗的是連結表本身的列，不是欄位）
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_album_title text;
  v_diary_body text;
  v_timeline_count int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.set_child_deleted(v_child, true);

  select title into v_album_title from public.albums
   where id = '4a000000-0000-4000-8000-000000000001';
  if v_album_title is null or not exists (
    select 1 from public.album_children
     where album_id = '4a000000-0000-4000-8000-000000000001' and child_id = v_child
  ) then
    raise exception 'FAIL：孩子被軟刪之後，掛在他底下的相簿消失或 album_children 的標記被拿掉了';
  end if;

  select body into v_diary_body from public.diaries
   where id = '5a000000-0000-4000-8000-000000000001';
  if v_diary_body is null or not exists (
    select 1 from public.diary_children
     where diary_id = '5a000000-0000-4000-8000-000000000001' and child_id = v_child
  ) then
    raise exception 'FAIL：孩子被軟刪之後，掛在他底下的日記消失或 diary_children 的標記被拿掉了';
  end if;

  -- get_family_timeline 對這個孩子的篩選行為完全不變（後端從不查 children.deleted_at）
  select count(*) into v_timeline_count from public.get_family_timeline(
    'fa000000-0000-4000-8000-000000000001', v_child, null, null, 20
  ) where kind in ('album', 'diary');
  if v_timeline_count < 2 then
    raise exception 'FAIL：孩子被軟刪之後，get_family_timeline 用 p_child_id 篩選這個孩子竟然少於 2 筆（相簿＋日記），實際 %', v_timeline_count;
  end if;

  reset role;
  raise notice 'ok：軟刪孩子完全不連動——掛在他底下的相簿／日記標記保留，get_family_timeline 的單寶貝篩選行為不變';
end;
$$;

rollback;

-- ===========================================================================
-- 9. 已軟刪的孩子不能再被指定為新內容的 child_id（R1 I3，LS044；LS-121 起守門
--    trigger 搬到 diary_children／album_children 連結表上，見 migration 第 5 段）
--    ——只在建立新標記時檢查，既有標記／內容繼續能軟刪／還原／編輯自己
--    （「既有內容不動」）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child_active uuid := '2a000000-0000-4000-8000-000000000001';
  v_child_deleted uuid;
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_diary uuid;
  v_album uuid;
  v_album_probe uuid;
  v_body text;
begin
  -- 建一個新孩子專門當「已軟刪」的目標，不動 00_fixtures 既有的兩個孩子
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_child_deleted := public.create_child(v_family, '已軟刪的孩子', date '2025-01-01', null);
  perform public.set_child_deleted(v_child_deleted, true);
  reset role;

  -- (a) create_diary_entry：p_child_ids 含已軟刪的孩子 → LS044
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, array[v_child_deleted]::uuid[], '想掛在已刪孩子底下', current_date);
    raise exception 'FAIL：create_diary_entry 竟然能把日記掛到已軟刪的孩子底下';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;

  -- 正向對照：child_id 指向 active 的孩子完全不受影響
  v_diary := public.create_diary_entry(v_family, array[v_child_active]::uuid[], '掛在還活著的孩子底下', current_date);
  if v_diary is null then
    raise exception 'FAIL：create_diary_entry 指向 active 孩子時竟然失敗了';
  end if;
  reset role;
  raise notice 'ok：create_diary_entry 指向已軟刪孩子拿 LS044，指向 active 孩子不受影響（正向對照）';

  -- (b) update_diary_entry：把 p_child_ids 改成含已軟刪的孩子 → LS044
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, '想改掛到已刪孩子底下', current_date, array[v_child_deleted]::uuid[]);
    raise exception 'FAIL：update_diary_entry 竟然能把日記改掛到已軟刪的孩子底下';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;

  -- (c)「既有內容不動」的正面證明：update_diary_entry 傳跟原本一樣的孩子集合
  -- （active，不是已軟刪那個）改 body，完全不受這支 trigger 影響——這裡驗的是
  -- diary_children 的 BEFORE INSERT trigger 只在真的插入新列時才檢查，覆蓋語意下
  -- 「刪多補少」對集合不變的孩子不會產生新的 INSERT（見 update_diary_entry 的
  -- 「刪多補少」實作：不在新集合裡的才刪、不在舊集合裡的才插，值沒變就兩邊都不動）。
  perform public.update_diary_entry(v_diary, '只改內容，孩子標記沒變', current_date, array[v_child_active]::uuid[]);
  select body into v_body from public.diaries where id = v_diary;
  if v_body <> '只改內容，孩子標記沒變' then
    raise exception 'FAIL：孩子標記不變時，update_diary_entry 改內容失敗了';
  end if;
  reset role;
  raise notice 'ok：update_diary_entry 把孩子標記改成已軟刪孩子拿 LS044；標記不變時單純改內容不受影響';

  -- (d) set_album_children：child_id 指向已軟刪的孩子 → LS044（LS-121 起
  -- album_children 對 authenticated 完全沒有直接寫入 grant，唯一路徑是這支 RPC
  -- ——albums 本體仍是 owner/member 直接 .insert()，只有孩子標記收斂進連結表，
  -- 這裡分兩步驗證同一支 trigger 對這條 RPC 寫入路徑一樣有效）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.albums (family_id, title, created_by)
  values (v_family, '想建在已刪孩子底下的相簿', v_owner)
  returning id into v_album_probe;
  begin
    perform public.set_album_children(v_album_probe, array[v_child_deleted]::uuid[]);
    raise exception 'FAIL：set_album_children 竟然能把相簿標記掛到已軟刪的孩子底下';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;

  insert into public.albums (family_id, title, created_by)
  values (v_family, '建在還活著的孩子底下的相簿', v_owner)
  returning id into v_album;
  perform public.set_album_children(v_album, array[v_child_active]::uuid[]);
  raise notice 'ok：set_album_children 指向已軟刪孩子拿 LS044，指向 active 孩子不受影響（正向對照）';

  -- (e)「既有內容不動」對 albums 也成立：owner 對這本相簿呼叫 set_album_deleted
  -- （只碰 deleted_at，不碰孩子標記）完全不受這支 trigger 影響，即使標記指向的
  -- 孩子之後被軟刪也一樣——這裡直接把這本相簿的孩子也軟刪掉，再驗證
  -- set_album_deleted 依然能正常運作。
  perform public.set_child_deleted(v_child_active, true);  -- 把這本相簿的孩子也軟刪
  begin
    perform public.set_album_deleted(v_album, true);
  exception when others then
    raise exception 'FAIL：孩子被軟刪之後，掛在他底下的相簿連軟刪自己都做不到了（錯誤碼 %）——「既有內容不動」被破壞', sqlstate;
  end;
  if (select deleted_at from public.albums where id = v_album) is null then
    raise exception 'FAIL：set_album_deleted 執行後 deleted_at 竟然還是 NULL';
  end if;
  perform public.set_child_deleted(v_child_active, false);  -- 還原，避免影響後面的測試檔
  reset role;
  raise notice 'ok：孩子被軟刪之後，掛在他底下的既有相簿仍能正常軟刪自己（LS044 只管「新標記」，不管「既有內容的其他操作」）';
end;
$$;

rollback;
