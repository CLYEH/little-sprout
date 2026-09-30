-- LS-408 驗收：孤兒相簿（作者已離開家庭／帳號已刪）由家庭 owner 接手編輯
--
-- 對應 20260930*_orphan_album_owner_edit.sql 的 albums_update policy 新增分支。角色沿用
-- 00_fixtures.sql 的 A 家：owner=a1、member=a2（作者）、viewer=a3；B 家 owner=b1 代表
-- 非本家庭成員；另在段內加 A 家第 4 位 member a4（非作者、非 owner）。每段各自
-- begin…rollback，不留殘料。
--
-- 直接 UPDATE 被 RLS 排除時 Postgres 不噴錯、影響 0 列（LS-52 migration 檔頭已解釋），
-- 所以「被拒」一律斷言 row_count=0＋內容逐字不變，不是 raise。
--
-- Mutation 自證（本票實跑，斷言原文見 PR 描述／handoff）：拿掉 policy 新增的孤兒分支
-- → §1 第一條「owner 應能改孤兒相簿標題」變紅。

\set ON_ERROR_STOP on

-- ===========================================================================
-- §1. 作者走真實 delete_my_account() 離開（family_members 列沒了、profiles 列還在）：
--     owner 可改標題與封面；非 owner 成員、他家 owner 都不行
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
  v_album uuid := 'ae000000-0000-4000-8000-000000000101';
  v_media uuid := '3a000000-0000-4000-8000-000000000002';
  v_n int;
  v_title text;
  v_cover uuid;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls408.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.albums (id, family_id, title, cover_media_id, created_by)
  values (v_album, v_family, '作者建的相簿', '3a000000-0000-4000-8000-000000000001', v_author);
  reset role;

  -- 作者刪帳號（LS-401：相簿保留，created_by 此時仍指向還在的 profile）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  -- 1. owner 改標題與封面：成功（本票新增分支）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'owner 接手改的標題', cover_media_id = v_media
   where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：作者離開後 owner 應能改孤兒相簿標題／封面，影響 % 列（預期 1）', v_n;
  end if;
  set local role postgres;
  select title, cover_media_id into v_title, v_cover from public.albums where id = v_album;
  reset role;
  if v_title <> 'owner 接手改的標題' or v_cover is distinct from v_media then
    raise exception 'FAIL：owner 更新後內容不符（title=% cover=%）', v_title, v_cover;
  end if;

  -- 2. 非 owner 成員（a4，member）改：影響 0 列、標題不變
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'HACKED-by-member' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：非 owner 的 member 不該能改孤兒相簿，影響 % 列（預期 0）', v_n;
  end if;

  -- 2b. viewer 同樣不行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'HACKED-by-viewer' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：viewer 不該能改孤兒相簿，影響 % 列（預期 0）', v_n;
  end if;

  -- 2c. 他家 owner（b1）不行（分支只認「我擁有的家庭」）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'HACKED-by-outsider' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：他家 owner 不該能改 A 家的孤兒相簿，影響 % 列（預期 0）', v_n;
  end if;

  set local role postgres;
  select title into v_title from public.albums where id = v_album;
  reset role;
  if v_title <> 'owner 接手改的標題' then
    raise exception 'FAIL：被拒的更新不該動到標題，現為 %', v_title;
  end if;

  -- 2d. owner 仍不能藉此改 deleted_at／created_by（欄位級 grant 只有 title／cover_media_id）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.albums set created_by = v_owner where id = v_album;
    reset role;
    raise exception 'FAIL：owner 不該能改孤兒相簿的 created_by（預期 42501）';
  exception when insufficient_privilege then
    reset role;
  end;

  raise notice 'OK §1：作者離開後 owner 可改標題／封面；member／viewer／他家 owner 被拒；created_by 不可改';
end;
$$;

rollback;

-- ===========================================================================
-- §1b. 作者的 auth.users 真的被刪（albums.created_by on delete set null → NULL）：
--      owner 可改；非 owner 成員不行
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_member_b uuid := 'a0000000-0000-4000-8000-000000000004';
  v_album uuid := 'ae000000-0000-4000-8000-000000000102';
  v_n int;
  v_created_by uuid;
  v_title text;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_member_b, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls408.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_member_b, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_member_b, 'member', true);

  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者建的相簿（帳號將被刪）', v_author);

  -- 模擬 finalize 後 auth.users 真的被刪：先離開家庭，再刪 profiles（FK set null）
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
  update public.albums set title = 'owner 改 NULL 作者相簿' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：created_by 為 NULL 的孤兒相簿 owner 應能改，影響 % 列（預期 1）', v_n;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'HACKED-by-member' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：created_by 為 NULL 時非 owner 成員不該能改，影響 % 列（預期 0）', v_n;
  end if;

  set local role postgres;
  select title into v_title from public.albums where id = v_album;
  reset role;
  if v_title <> 'owner 改 NULL 作者相簿' then
    raise exception 'FAIL：標題應為 owner 改的版本，現為 %', v_title;
  end if;

  raise notice 'OK §1b：created_by=NULL 的孤兒相簿 owner 可改、member 被拒';
end;
$$;

rollback;

-- ===========================================================================
-- §2. 作者仍在家庭：owner 不得改（既有契約不退步）；作者本人仍可改
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_album uuid := 'ae000000-0000-4000-8000-000000000103';
  v_n int;
  v_title text;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, '作者仍在的相簿', v_author);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'HACKED-by-owner' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：作者仍在家庭時 owner 不該能改該相簿，影響 % 列（預期 0）', v_n;
  end if;

  set local role postgres;
  select title into v_title from public.albums where id = v_album;
  reset role;
  if v_title <> '作者仍在的相簿' then
    raise exception 'FAIL：被拒的更新不該動到標題，現為 %', v_title;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = '作者自己改' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：作者本人應仍能改自己的相簿，影響 % 列（預期 1）', v_n;
  end if;

  raise notice 'OK §2：作者仍在時 owner 被拒、作者本人可改';
end;
$$;

rollback;

-- ===========================================================================
-- §3. owner 改自己建的相簿（不退步）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_album uuid := 'ae000000-0000-4000-8000-000000000104';
  v_n int;
  v_title text;
begin
  set local role postgres;
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, 'owner 自己的相簿', v_owner);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'owner 改自己的' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：owner 應能改自己建的相簿，影響 % 列（預期 1）', v_n;
  end if;

  set local role postgres;
  select title into v_title from public.albums where id = v_album;
  reset role;
  if v_title <> 'owner 改自己的' then
    raise exception 'FAIL：標題應為 owner 改的版本，現為 %', v_title;
  end if;

  raise notice 'OK §3：owner 改自己建的相簿不退步';
end;
$$;

rollback;
