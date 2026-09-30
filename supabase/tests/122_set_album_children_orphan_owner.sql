-- LS-409 驗收：set_album_children 放行「owner 且相簿為孤兒」（與 LS-408 albums_update 同判定）
--
-- 對應 20260930*_set_album_children_orphan_owner.sql。角色沿用 00_fixtures.sql 的 A 家：
-- owner=a1、member=a2（作者）、viewer=a3；B 家 owner=b1 代表他家 owner；段內另加 A 家第 4 位
-- member a4（非作者、非 owner）。每段各自 begin…rollback，不留殘料。
--
-- set_album_children 是 RPC，被拒時 raise LS045（不像直接 UPDATE 的靜默 0 列），所以「被拒」
-- 斷言的是 sqlstate=LS045＋album_children 內容逐字不變。
--
-- Mutation 自證（本票實跑，斷言原文見 PR 描述／handoff）：拿掉 RPC 的 owner-on-orphan 放行分支
-- → §1 第一條「owner 應能對孤兒相簿設寶貝標記」變紅。

\set ON_ERROR_STOP on

-- ===========================================================================
-- §1. 作者走真實 delete_my_account() 離開：owner 可設標記；非 owner 成員／他家 owner 被拒
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider_owner uuid := 'b0000000-0000-4000-8000-000000000001';
  v_album uuid := 'ae000000-0000-4000-8000-000000000201';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_n int;
  v_state text;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls409.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者建的相簿', v_author);
  reset role;

  -- 作者刪帳號（LS-401：相簿保留，created_by 仍指向還在的 profile）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  -- 1. owner 對孤兒相簿設寶貝標記：成功（本票新增分支）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
  exception when sqlstate 'LS045' then
    reset role;
    raise exception 'FAIL：作者離開後 owner 應能對孤兒相簿設寶貝標記，卻被 LS045 拒絕';
  end;
  reset role;
  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album and child_id = v_child;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：owner 設標記後 album_children 應有 1 列，實際 %', v_n;
  end if;

  -- 1b. owner 再清空標記（p_child_ids 空陣列＝清空）也成功
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_children(v_album, array[]::uuid[]);
  reset role;
  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：owner 清空標記後 album_children 應為 0 列，實際 %', v_n;
  end if;

  -- 2. 非 owner 成員 a4／viewer／他家 owner：LS045，標記不變
  foreach v_state in array array['a4', 'viewer', 'outsider']
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',
        case v_state when 'a4' then v_other_member when 'viewer' then v_viewer else v_outsider_owner end,
        'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
      perform public.set_album_children(v_album, array[v_child]);
      reset role;
      raise exception 'FAIL：% 不該能對孤兒相簿設寶貝標記（預期 LS045）', v_state;
    exception when sqlstate 'LS045' then
      reset role;
    end;
  end loop;

  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：被拒的呼叫不該動到標記，album_children 現有 % 列', v_n;
  end if;

  raise notice 'OK §1：作者離開後 owner 可設／清標記；member／viewer／他家 owner LS045';
end;
$$;

rollback;

-- ===========================================================================
-- §1b. created_by 為 NULL（auth.users 真的被刪）：owner 可設；非 owner 成員 LS045
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid := 'ae000000-0000-4000-8000-000000000202';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_created_by uuid;
  v_n int;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者帳號已刪的相簿', v_author);
  delete from public.family_members where family_id = v_family and user_id = v_author;
  delete from public.profiles where id = v_author;
  select created_by into v_created_by from public.albums where id = v_album;
  reset role;
  if v_created_by is not null then
    raise exception 'FAIL：前置條件不成立，albums.created_by 應為 NULL，實際 %', v_created_by;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
  exception when sqlstate 'LS045' then
    reset role;
    raise exception 'FAIL：created_by 為 NULL 的孤兒相簿 owner 應能設標記，卻被 LS045 拒絕';
  end;
  reset role;
  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：created_by=NULL 相簿 owner 設標記後應有 1 列，實際 %', v_n;
  end if;

  raise notice 'OK §1b：created_by=NULL 的孤兒相簿 owner 可設標記';
end;
$$;

rollback;

-- ===========================================================================
-- §2. 作者仍在家庭：owner 呼叫 LS045（既有契約不退步）；作者本人仍可
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid := 'ae000000-0000-4000-8000-000000000203';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_n int;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者仍在的相簿', v_author);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
    reset role;
    raise exception 'FAIL：作者仍在家庭時 owner 不該能設標記（預期 LS045）';
  exception when sqlstate 'LS045' then
    reset role;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_children(v_album, array[v_child]);
  reset role;
  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：作者本人應仍能設標記，album_children 應有 1 列，實際 %', v_n;
  end if;

  raise notice 'OK §2：作者仍在時 owner LS045、作者本人可設';
end;
$$;

rollback;

-- ===========================================================================
-- §2b. 作者被降級成 viewer（仍在 family_members）不算孤兒：owner LS045（沿 LS-408 §2b）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid := 'ae000000-0000-4000-8000-000000000204';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_role text;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者被降級的相簿', v_author);
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  select role::text into v_role from public.family_members
   where family_id = v_family and user_id = v_author;
  reset role;
  if v_role is distinct from 'viewer' then
    raise exception 'FAIL：前置條件不成立，作者應已降級為 viewer 且仍在 family_members，實際 role=%', v_role;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
    reset role;
    raise exception 'FAIL：作者被降級成 viewer（仍在家庭）不算孤兒，owner 不該能設標記（預期 LS045）';
  exception when sqlstate 'LS045' then
    reset role;
  end;

  raise notice 'OK §2b：降級成 viewer 的作者不算孤兒，owner LS045';
end;
$$;

rollback;

-- ===========================================================================
-- §3. 停用家庭／停權 owner：孤兒判定沿 owned_family_ids() 的停權過濾，不放行
--     （helper 不加過濾的理由見 migration 檔頭；過濾由 owned_family_ids() 承擔）。
--     斷言「授權關卡就得 LS045」：album_children 的 enforce_not_suspended trigger 是第二道
--     防線，但不該由它來擋（它的錯誤碼不是 LS045、且訊息面向使用者的暫停通知）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid := 'ae000000-0000-4000-8000-000000000205';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_n int;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '孤兒相簿（停權測試）', null);
  update public.families set suspended_at = now() where id = v_family;
  reset role;

  -- 3a. 家庭停用：owner 呼叫 LS045
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
    reset role;
    raise exception 'FAIL：家庭已停用時 owner 不該能對孤兒相簿設標記（預期 LS045）';
  exception when sqlstate 'LS045' then
    reset role;
  when others then
    reset role;
    raise exception 'FAIL：家庭已停用時 owner 應在授權關卡得 LS045，實際 % %', sqlstate, sqlerrm;
  end;

  -- 3b. 家庭恢復、owner 帳號被停權：同樣 LS045
  set local role postgres;
  update public.families set suspended_at = null where id = v_family;
  update public.profiles set suspended_at = now() where id = v_owner;
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child]);
    reset role;
    raise exception 'FAIL：owner 帳號被停權時不該能對孤兒相簿設標記（預期 LS045）';
  exception when sqlstate 'LS045' then
    reset role;
  when others then
    reset role;
    raise exception 'FAIL：owner 帳號被停權時應在授權關卡得 LS045，實際 % %', sqlstate, sqlerrm;
  end;

  set local role postgres;
  select count(*) into v_n from public.album_children where album_id = v_album;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：被拒的呼叫不該動到標記，album_children 現有 % 列', v_n;
  end if;

  raise notice 'OK §3：家庭停用／owner 停權時孤兒相簿 owner 仍 LS045';
end;
$$;

rollback;
