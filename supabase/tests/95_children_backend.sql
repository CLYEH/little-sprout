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
-- 1. 寫入面收斂：children 的直接 INSERT／UPDATE 對所有角色都必須被擋（policy + grant 兩層）
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

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 children 的直接 INSERT／UPDATE 皆被擋下 (42501)';
end;
$$;

-- 欄位級對帳：連「有沒有任何一欄的 UPDATE/INSERT grant」都要驗過（同 85_ 對 diaries 的
-- 慣例），只驗整表的斷言測不出欄位級 grant 忘了收回。SELECT／DELETE 的正向對照確保
-- 收斂沒有連帶把讀取與硬刪的路徑也關掉。
do $$
begin
  if has_any_column_privilege('authenticated', 'public.children', 'insert') then
    raise exception 'FAIL：authenticated 還有 children 的 INSERT 授權（表級或任一欄位級）—— create_child 的邊界形同虛設';
  end if;
  if has_any_column_privilege('authenticated', 'public.children', 'update') then
    raise exception 'FAIL：authenticated 還有 children 的 UPDATE 授權（表級或任一欄位級）—— update_child/set_child_deleted 的邊界形同虛設';
  end if;
  if not has_table_privilege('authenticated', 'public.children', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 children 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.children', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 children 的 DELETE grant（owner 硬刪的路徑，未受本票影響）';
  end if;
  raise notice 'ok：children 授權兩層對帳——INSERT/UPDATE 無任何形態的 grant，SELECT/DELETE 原樣保留';
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
-- 4. family_id 不可變 trigger：任何 UPDATE 想搬動 family_id 一律被擋 (LS040)，
--    不論呼叫者是誰——這裡直接以資料庫層級的身分（bypass RLS）驗證，證明防線不是
--    只靠 RPC 參數沒有 p_family_id，是 trigger 本身真的會擋。
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
  exception when sqlstate 'LS040' then
    null;  -- ok
  end;

  if (select family_id from public.children where id = v_child) <> v_family_a then
    raise exception 'FAIL：即使拿到 LS040，family_id 實際上還是被改動了';
  end if;

  -- 正向對照：改別的欄位（不含 family_id）不受 trigger 影響
  update public.children set name = '換個名字沒問題' where id = v_child;
  if (select name from public.children where id = v_child) <> '換個名字沒問題' then
    raise exception 'FAIL：trigger 誤擋了不含 family_id 的 UPDATE';
  end if;

  raise notice 'ok：children.family_id 建立後不可變 (LS040)，其餘欄位的 UPDATE 不受影響';
end;
$$;

rollback;

-- ===========================================================================
-- 5. set_child_deleted：僅 owner；寫 deleted_at／deleted_by；軟刪／還原皆 idempotent；
--    不存在的孩子 (LS041)
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

  -- 軟刪 idempotent：再次呼叫 true 會刷新 deleted_at（不報錯）
  perform pg_sleep(0.01);
  perform public.set_child_deleted(v_child, true);
  select deleted_at into v_row.deleted_at from public.children where id = v_child;
  if v_row.deleted_at is null then
    raise exception 'FAIL：重複軟刪之後 deleted_at 變成 NULL';
  end if;

  -- owner 還原：30 天內，deleted_at／deleted_by 清成 NULL
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
  reset role;
  raise notice 'ok：owner 軟刪／還原正確寫入 deleted_at／deleted_by，兩個方向皆 idempotent';

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
-- 7. list_children：成員可讀；已軟刪的列（含旗標）只有 owner 看得到，
--    member／viewer 完全查不到那些列（不是欄位被隱藏，是整列消失）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_active uuid;
  v_deleted uuid;
  v_count int;
  v_deleted_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_active := public.create_child(v_family, 'Active 孩子', date '2025-01-01', null);
  v_deleted := public.create_child(v_family, 'Deleted 孩子', date '2025-01-01', null);
  perform public.set_child_deleted(v_deleted, true);

  -- owner：看得到 active + 已軟刪兩列，且已軟刪那列的 deleted_at 有值（旗標可見）
  select count(*) into v_count from public.list_children(v_family)
   where id in (v_active, v_deleted);
  if v_count <> 2 then
    raise exception 'FAIL：owner 呼叫 list_children 應看到 2 列（active＋已軟刪），實際 %', v_count;
  end if;
  select deleted_at into v_deleted_at from public.list_children(v_family) where id = v_deleted;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 呼叫 list_children，已軟刪孩子的 deleted_at 旗標竟然是 NULL';
  end if;
  reset role;
  raise notice 'ok：owner 呼叫 list_children 看得到 active＋已軟刪兩列，旗標（deleted_at）正確可見';

  -- member：只看得到 active 那一列，已軟刪的完全不在結果裡
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.list_children(v_family) where id = v_active;
  if v_count <> 1 then
    raise exception 'FAIL：member 呼叫 list_children 看不到 active 孩子';
  end if;
  select count(*) into v_count from public.list_children(v_family) where id = v_deleted;
  if v_count <> 0 then
    raise exception 'FAIL：member 呼叫 list_children 竟然看得到已軟刪的孩子（應完全篩掉，不是 % 列）', v_count;
  end if;
  reset role;

  -- viewer：同 member
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.list_children(v_family) where id = v_deleted;
  if v_count <> 0 then
    raise exception 'FAIL：viewer 呼叫 list_children 竟然看得到已軟刪的孩子';
  end if;
  reset role;
  raise notice 'ok：member／viewer 呼叫 list_children 只看得到 active 孩子，已軟刪的整列消失（非欄位隱藏）';

  -- 直接 .from("children").select() 走同一條 RLS，行為必須與 RPC 一致
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.children where id = v_deleted;
  if v_count <> 0 then
    raise exception 'FAIL：member 直接 SELECT children 竟然看得到已軟刪的孩子——RLS 沒有真的收斂';
  end if;
  reset role;
  raise notice 'ok：直接 .from("children").select() 與 list_children 行為一致，收斂在 RLS 這一層';

  -- 未登入：0 列，不報錯
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  select count(*) into v_count from public.list_children(v_family);
  if v_count <> 0 then
    raise exception 'FAIL：未登入呼叫 list_children 竟然回傳非 0 列';
  end if;
  reset role;
  raise notice 'ok：未登入呼叫 list_children 回傳 0 列，不報錯';
end;
$$;

rollback;

-- ===========================================================================
-- 8. 軟刪不連動：照片／日記掛在被軟刪孩子的 child_id 下者完全保留
--    （重用 00_fixtures 既有的 album 4a／diary 5a，兩者都掛在 child 2a 底下）
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
   where id = '4a000000-0000-4000-8000-000000000001' and child_id = v_child;
  if v_album_title is null then
    raise exception 'FAIL：孩子被軟刪之後，掛在他底下的相簿消失或 child_id 被改動了';
  end if;

  select body into v_diary_body from public.diaries
   where id = '5a000000-0000-4000-8000-000000000001' and child_id = v_child;
  if v_diary_body is null then
    raise exception 'FAIL：孩子被軟刪之後，掛在他底下的日記消失或 child_id 被改動了';
  end if;

  -- get_family_timeline 對這個孩子的篩選行為完全不變（後端從不查 children.deleted_at）
  select count(*) into v_timeline_count from public.get_family_timeline(
    'fa000000-0000-4000-8000-000000000001', v_child, null, null, 20
  ) where kind in ('album', 'diary');
  if v_timeline_count < 2 then
    raise exception 'FAIL：孩子被軟刪之後，get_family_timeline 用 p_child_id 篩選這個孩子竟然少於 2 筆（相簿＋日記），實際 %', v_timeline_count;
  end if;

  reset role;
  raise notice 'ok：軟刪孩子完全不連動——掛在他底下的相簿／日記保留，get_family_timeline 的單寶貝篩選行為不變';
end;
$$;

rollback;
