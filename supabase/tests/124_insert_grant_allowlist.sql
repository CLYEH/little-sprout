-- LS-414 — 欄位級 INSERT 允許清單收斂：member 以 member 身分（走 RLS，不是 postgres）
-- 直接對 `albums`／`content_reports`／`media`／`profiles` 的伺服器專屬欄位送原始
-- INSERT，驗證一律 42501；不帶這些欄位的正常 INSERT 仍成功（見
-- 20260930040631_insert_grant_allowlist.sql）。角色矩陣沿用 00_fixtures.sql：
-- A 家（fa…001）owner=a1（a0…001）、member=a2（a0…002）、viewer=a3（a0…003）。
--
-- Mutation 自證（開發期本機 `supabase db reset` 後，單檔手動把欄位加回 grant，
-- 再跑本檔；各自單獨套用、精準命中對應斷言，實跑原文見 PR body／handoff）：
--   M1：`grant insert (deleted_at, deleted_by) on public.albums to authenticated;` → §1
--   M2：`grant insert (status) on public.content_reports to authenticated;` → §2
--   M3：`grant insert (deleted_at) on public.media to authenticated;` → §3
--   M4：`grant insert (suspended_at, eula_accepted_version, …) on public.profiles …` → §4

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. albums.deleted_at／deleted_by：member 直接 INSERT 帶這兩欄一律 42501；不帶成功
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_owner  uuid := 'a0000000-0000-4000-8000-000000000001';
  v_album uuid;
  v_del timestamptz;
  v_by uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.albums (family_id, title, created_by, deleted_at)
    values (v_family, 'LS414 出生即軟刪的相簿', v_member, now() - interval '1 day');
    raise exception 'FAIL：member 直接 INSERT albums.deleted_at 竟然成功——繞過 set_album_deleted 唯一路徑';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.albums (family_id, title, created_by, deleted_by)
    values (v_family, 'LS414 偽造 deleted_by 的相簿', v_member, v_owner);
    raise exception 'FAIL：member 直接 INSERT albums.deleted_by＝別人 竟然成功——刪除歸屬可被偽造';
  exception when insufficient_privilege then
    null;
  end;

  -- 正向對照：不帶這兩欄的正常建立成功，且兩欄皆為 NULL。
  insert into public.albums (family_id, title, created_by)
  values (v_family, 'LS414 正常建立的相簿', v_member)
  returning id into v_album;
  select deleted_at, deleted_by into v_del, v_by from public.albums where id = v_album;
  if v_del is not null or v_by is not null then
    raise exception 'FAIL：正常建立的相簿 deleted_at／deleted_by 竟然不是 NULL（%／%）', v_del, v_by;
  end if;
  reset role;
  raise notice 'ok：member 直接 INSERT albums.deleted_at／deleted_by 皆被 42501 擋下；不帶的正常建立仍成功';
end;
$$;

rollback;

-- ===========================================================================
-- 2. content_reports.status：檢舉者直接 INSERT 帶 status 一律 42501；不帶成功（default
--    pending）；report_content RPC（SECURITY DEFINER）不受影響
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_target uuid := '4a000000-0000-4000-8000-000000000001';
  v_status text;
  v_rpc uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.content_reports (family_id, target_type, target_id, reporter_id, reason, status)
    values (v_family, 'album', v_target, v_member, 'LS414 自帶已結案', 'resolved');
    raise exception 'FAIL：檢舉者直接 INSERT content_reports.status=''resolved'' 竟然成功——繞過「只有 owner 能結案」';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.content_reports (family_id, target_type, target_id, reporter_id, reason, status)
    values (v_family, 'album', v_target, v_member, 'LS414 自帶駁回', 'dismissed');
    raise exception 'FAIL：檢舉者直接 INSERT content_reports.status=''dismissed'' 竟然成功——dismissed 保留給平台方';
  exception when insufficient_privilege then
    null;
  end;

  -- 正向對照：不帶 status 的直接 INSERT 成功，吃 default 'pending'。
  insert into public.content_reports (family_id, target_type, target_id, reporter_id, reason)
  values (v_family, 'album', v_target, v_member, 'LS414 正常直接 INSERT')
  returning status::text into v_status;
  if v_status <> 'pending' then
    raise exception 'FAIL：不帶 status 的檢舉 status 竟然不是 pending（%）', v_status;
  end if;

  -- report_content RPC 仍可用（換一個目標，避開上面那筆的去重）。
  select public.report_content(v_family, 'diary', '5a000000-0000-4000-8000-000000000001', 'LS414 RPC 檢舉')
    into v_rpc;
  if v_rpc is null then
    raise exception 'FAIL：report_content RPC 在收斂 status INSERT 之後沒有回傳 id';
  end if;
  reset role;
  if (select status::text from public.content_reports where id = v_rpc) <> 'pending' then
    raise exception 'FAIL：report_content RPC 建立的檢舉 status 不是 pending';
  end if;
  raise notice 'ok：直接 INSERT content_reports.status（resolved／dismissed）被 42501 擋下；不帶 status 成功且為 pending；report_content RPC 仍成功';
end;
$$;

rollback;

-- ===========================================================================
-- 3. media.deleted_at：處置＝撤（出生即軟刪的列不計入 storage_used_bytes、不進 feed，
--    卻已佔 Storage）。member 直接 INSERT 帶 deleted_at 一律 42501；不帶成功且入帳；
--    軟刪的合法路徑（UPDATE deleted_at）不受影響
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_id uuid := gen_random_uuid();
  v_before bigint;
  v_after bigint;
begin
  select storage_used_bytes into v_before from public.families where id = v_family;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.media (
      family_id, storage_path, type, byte_size, width, height, uploaded_by, deleted_at
    ) values (
      v_family, v_family::text || '/2026/09/ls414-born-deleted.jpg', 'photo', 5000000, 100, 100,
      v_member, now() - interval '1 day'
    );
    raise exception 'FAIL：member 直接 INSERT media.deleted_at 竟然成功——出生即軟刪的列不計入額度';
  exception when insufficient_privilege then
    null;
  end;

  -- 正向對照：不帶 deleted_at 的上傳成功、入帳；再走合法軟刪路徑（UPDATE）成功、扣帳。
  insert into public.media (id, family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values (v_id, v_family, v_family::text || '/2026/09/ls414-ok.jpg', 'photo', 4096, 100, 100, v_member);
  reset role;
  select storage_used_bytes into v_after from public.families where id = v_family;
  if v_after - v_before <> 4096 then
    raise exception 'FAIL：正常上傳的 media 沒有入帳（before=%，after=%）', v_before, v_after;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.media set deleted_at = now() where id = v_id;
  reset role;
  select storage_used_bytes into v_after from public.families where id = v_family;
  if v_after <> v_before then
    raise exception 'FAIL：UPDATE deleted_at 軟刪路徑被打壞（after=%，預期回到 before=%）', v_after, v_before;
  end if;
  raise notice 'ok：member 直接 INSERT media.deleted_at 被 42501 擋下；不帶時正常上傳入帳、UPDATE deleted_at 軟刪照常扣帳';
end;
$$;

rollback;

-- ===========================================================================
-- 4. profiles 伺服器專屬旗標：INSERT 一律 42501（UPDATE 早已只開 display_name／avatar_url）；
--    不帶這些欄位的 `ensureProfileExists` 形狀（id, display_name）仍成功
-- ===========================================================================
begin;

do $$
declare
  v_user uuid := 'a0000000-0000-4000-8000-0000000004f4';
  v_col text;
  v_val text;
begin
  -- 沒有 profile 列的登入者：auth.users 的 AFTER INSERT trigger 會自動建列，先刪掉，
  -- 才走得到 authenticated 的 INSERT 路徑（否則只會撞 PK，測不到 grant）。
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ls414-noprofile@ls414.test', now(), now(), '{}', '{}');
  delete from public.profiles where id = v_user;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  set local role authenticated;

  for v_col, v_val in
    select * from (values
      ('deletion_requested_at', 'now()'),
      ('purged_at', 'now()'),
      ('suspended_at', 'now()'),
      ('eula_accepted_version', '''9.9'''),
      ('eula_accepted_at', 'now()')
    ) t(c, v)
  loop
    begin
      execute format('insert into public.profiles (id, display_name, %I) values ($1, ''LS414'', %s)', v_col, v_val)
        using v_user;
      raise exception 'FAIL：authenticated 直接 INSERT profiles.% 竟然成功——UPDATE 收斂被 INSERT 路徑繞過', v_col;
    exception when insufficient_privilege then
      null;
    end;
  end loop;

  -- 正向對照：ensureProfileExists 形狀（id, display_name）成功，旗標欄皆為 NULL。
  insert into public.profiles (id, display_name) values (v_user, 'LS414 正常建立');
  reset role;
  if exists (
    select 1 from public.profiles
     where id = v_user
       and (deletion_requested_at is not null or purged_at is not null or suspended_at is not null
            or eula_accepted_version is not null or eula_accepted_at is not null)
  ) then
    raise exception 'FAIL：正常建立的 profile 旗標欄竟然不是 NULL';
  end if;
  raise notice 'ok：直接 INSERT profiles 五個伺服器專屬旗標欄皆被 42501 擋下；(id, display_name) 形狀仍成功';
end;
$$;

rollback;
