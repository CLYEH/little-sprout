-- LS-151（LS-24 拆票之二）驗收：過渡期擋寫（deletion_requested_at 非 NULL 時
-- families／family_members／media／diaries／albums／children／comments 的
-- BEFORE INSERT 一律拒絕，LS051）＋ service_role 對 profiles 的 grant。
--
-- 每段自己 begin…rollback，不需要額外 cleanup；直接用 postgres 身分 UPDATE
-- profiles.deletion_requested_at 模擬「已呼叫過 delete_my_account()」的狀態
-- （比正式呼叫 delete_my_account() 更精準地單獨測 guard trigger 本身的行為，
-- 不糾結於 delete_my_account() 三種結果各自的家庭去留邏輯——那些已由
-- supabase/tests/91_delete_account.sql 覆蓋）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 0. 正向對照：service_role 對 profiles 只有 SELECT，沒有 UPDATE（LS-151 grant）
-- ===========================================================================
do $$
begin
  if not has_table_privilege('service_role', 'public.profiles', 'select') then
    raise exception 'FAIL：service_role 沒有 profiles 的 SELECT grant——Edge Function delete-account 讀不到 deletion_requested_at';
  end if;
  if has_table_privilege('service_role', 'public.profiles', 'update') then
    raise exception 'FAIL：service_role 竟然有 profiles 的 UPDATE grant（本票只該開 SELECT，見 migration 檔頭）';
  end if;
  raise notice 'ok：service_role 對 profiles 只有 SELECT（Edge Function 需要的最小集），沒有 UPDATE';
end;
$$;

-- ===========================================================================
-- 0b.（orchestrator 2026-09-03 協調，LS-153 R2 tombstone 取捨）驗證
-- `ensureProfileExists`（SupabaseFamilyAPIClient.swift:51-58）的 upsert 路徑不會
-- 把已標記 deletion_requested_at 的列覆寫回 NULL——client 用
-- `.upsert(payload, onConflict: "id", ignoreDuplicates: true)`，底層送
-- `Prefer: resolution=ignore-duplicates`，PostgREST 轉譯成
-- `insert ... on conflict (id) do nothing`，這裡直接用同樣的 SQL 語意模擬同一個
-- REST 呼叫，證明撞到既有列（不論是不是過渡期）時完全不執行 UPDATE，
-- deletion_requested_at／display_name 皆維持原值——不需要額外的 trigger／policy
-- （LS-153 若改成 tombstone 不硬刪 profiles，這一列會一直存在，`ensureProfileExists`
-- 因此永遠撞 conflict、永遠 do nothing，帳號不會被這條路徑「復活」）。
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_requested_before timestamptz;
  v_display_before text;
  v_requested_after timestamptz;
  v_display_after text;
begin
  set local role postgres;
  update public.profiles set deletion_requested_at = now() where id = v_member;
  select deletion_requested_at, display_name into v_requested_before, v_display_before
    from public.profiles where id = v_member;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- 同 ensureProfileExists 送出的語意：insert ... on conflict (id) do nothing。
  insert into public.profiles (id, display_name) values (v_member, '被 upsert 想改成的新名字')
    on conflict (id) do nothing;
  reset role;

  set local role postgres;
  select deletion_requested_at, display_name into v_requested_after, v_display_after
    from public.profiles where id = v_member;
  reset role;

  if v_requested_after is distinct from v_requested_before then
    raise exception 'FAIL：ensureProfileExists 語意的 upsert 竟然改動了 deletion_requested_at（%→%）',
      v_requested_before, v_requested_after;
  end if;
  if v_display_after is distinct from v_display_before then
    raise exception 'FAIL：ensureProfileExists 語意的 upsert 竟然改動了 display_name（%→%），ON CONFLICT DO NOTHING 沒有生效',
      v_display_before, v_display_after;
  end if;

  raise notice 'ok：ensureProfileExists 的 on conflict (id) do nothing 語意確認不會覆寫既有列（含 deletion_requested_at／display_name），過渡期帳號不會被這條路徑復活';
end;
$$;

rollback;

-- ===========================================================================
-- 1. 控制組：一般使用者（deletion_requested_at 是 NULL）建立新家庭、上傳、
--    建立內容都正常成功——guard 不誤傷正常使用者
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';  -- A 家 member（fixtures）
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.albums (family_id, title, created_by)
  values (v_family, '控制組相簿', v_member);

  perform public.create_comment(v_family, 'media', '3a000000-0000-4000-8000-000000000001', '控制組留言');

  reset role;

  select count(*) into v_n from public.albums where title = '控制組相簿';
  if v_n <> 1 then
    raise exception 'FAIL：控制組（未請求刪除的一般成員）建立相簿竟然失敗，guard 誤傷正常使用者';
  end if;

  raise notice 'ok：控制組——deletion_requested_at 為 NULL 的一般成員，建立相簿／留言不受 guard 影響';
end;
$$;

rollback;

-- ===========================================================================
-- 2. create_family（直接 INSERT INTO families）在過渡期被擋——這是 LS-143
--    merge-review R1 i1 指出的核心風險：擋住這條路徑，「過渡期又成為某個家庭
--    唯一 owner」從源頭不可能發生
-- ===========================================================================
begin;

do $$
declare
  v_solo uuid := 'c1000000-0000-4000-8000-000000000001';
  v_n int;
  v_raised boolean := false;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_solo, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls151-solo@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name, deletion_requested_at)
  values (v_solo, 'LS151 過渡期測試帳號', now())
    on conflict (id) do update set deletion_requested_at = excluded.deletion_requested_at;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_solo, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.families (name, created_by) values ('過渡期新家庭', v_solo);
    raise exception 'FAIL：deletion_requested_at 非 NULL 的使用者竟然能建立新家庭';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL：LS051 沒有被觸發';
  end if;

  set local role postgres;
  select count(*) into v_n from public.families where name = '過渡期新家庭';
  if v_n <> 0 then
    raise exception 'FAIL：families 列竟然還是被建立了（trigger 擋下應該讓整個 INSERT 連同 cascade 的 owner 寫入一起失敗）';
  end if;
  select count(*) into v_n from public.family_members where user_id = v_solo;
  if v_n <> 0 then
    raise exception 'FAIL：被擋下的家庭建立竟然還是留下了 family_members 列';
  end if;

  raise notice 'ok：create_family（過渡期）被擋（LS051），沒有留下任何 families／family_members 殘餘列';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 端到端：過渡期使用者無法建立新家庭 → service_role 刪除 auth.users 時
--    cascade 到 family_members 不會撞見 LS001（因為根本沒有任何一列可 cascade）
-- ===========================================================================
begin;

do $$
declare
  v_solo uuid := 'c2000000-0000-4000-8000-000000000001';
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_solo, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls151-e2e@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name, deletion_requested_at)
  values (v_solo, 'LS151 端到端測試帳號', now())
    on conflict (id) do update set deletion_requested_at = excluded.deletion_requested_at;
  reset role;

  -- 過渡期嘗試建立家庭（模擬使用者在窗口內的破壞性動作），必須被擋
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_solo, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.families (name, created_by) values ('端到端測試家庭', v_solo);
    raise exception 'FAIL：端到端案例竟然能建立新家庭';
  exception when sqlstate 'LS051' then
    null;  -- ok
  end;
  reset role;

  -- Edge Function 的核心動作：service_role 身分刪 auth.users，cascade 掉 profiles。
  -- 這裡就是 LS-143 R1 i1 指出「可能撞見 LS001」的那一步——因為上面的 INSERT 被擋，
  -- 這個使用者從沒有取得任何一列 family_members，這句 DELETE 不會 cascade 到任何
  -- family_members 列，自然不會有 LS001。
  set local role postgres;
  delete from auth.users where id = v_solo;

  select count(*) into v_n from public.profiles where id = v_solo;
  if v_n <> 0 then
    raise exception 'FAIL：刪除 auth.users 之後 profiles 列竟然還在（cascade 沒有生效）';
  end if;

  raise notice 'ok：端到端——過渡期建立家庭被擋 → service_role 刪除 auth.users cascade 成功，沒有撞見 LS001';
end;
$$;

rollback;

-- ===========================================================================
-- 4. 上傳（media 直接 INSERT）在過渡期被擋
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_media uuid := 'c3000000-0000-4000-8000-000000000001';
  v_n int;
  v_raised boolean := false;
begin
  set local role postgres;
  update public.profiles set deletion_requested_at = now() where id = v_member;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
    values (v_media, v_family, v_family::text || '/2026/09/' || v_media::text || '.jpg',
            'photo', 1048576, now(), 100, 100, v_member);
    raise exception 'FAIL：過渡期使用者竟然能上傳照片';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL：LS051 沒有被觸發（media 上傳）';
  end if;

  set local role postgres;
  select count(*) into v_n from public.media where id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL：被擋下的上傳竟然還是留下了 media 列';
  end if;

  raise notice 'ok：上傳（過渡期）被擋（LS051）';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 建立內容：diaries（create_diary_entry）／albums（直接 INSERT）／
--    children（create_child）／comments（create_comment）在過渡期皆被擋
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_raised boolean;
begin
  set local role postgres;
  update public.profiles set deletion_requested_at = now() where id = v_member;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- diaries：create_diary_entry
  v_raised := false;
  begin
    perform public.create_diary_entry(v_family, '{}'::uuid[], '過渡期日記', current_date);
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'FAIL：過渡期使用者竟然能 create_diary_entry';
  end if;

  -- albums：直接 INSERT
  v_raised := false;
  begin
    insert into public.albums (family_id, title, created_by) values (v_family, '過渡期相簿', v_member);
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'FAIL：過渡期使用者竟然能直接 INSERT albums';
  end if;

  -- children：create_child
  v_raised := false;
  begin
    perform public.create_child(v_family, '過渡期寶貝', date '2024-01-01', null);
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'FAIL：過渡期使用者竟然能 create_child';
  end if;

  -- comments：create_comment
  v_raised := false;
  begin
    perform public.create_comment(v_family, 'media', '3a000000-0000-4000-8000-000000000001', '過渡期留言');
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'FAIL：過渡期使用者竟然能 create_comment';
  end if;

  reset role;
  raise notice 'ok：建立內容（diaries／albums／children／comments）在過渡期皆被擋（LS051）';
end;
$$;

rollback;

-- ===========================================================================
-- 6. approve_join（family_members INSERT）在過渡期被擋——即使呼叫者是合法
--    owner、申請本身完全有效，過渡期一樣不放行
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'b0000000-0000-4000-8000-000000000001';  -- B 家 owner（fixtures）
  v_family uuid := 'fb000000-0000-4000-8000-000000000001';
  v_invite uuid := '1b000000-0000-4000-8000-000000000001';  -- B 家既有邀請碼（fixtures）
  v_applicant uuid := 'c4000000-0000-4000-8000-000000000001';
  v_request uuid;
  v_n int;
  v_raised boolean := false;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_applicant, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls151-applicant@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_applicant, 'LS151 申請人測試帳號')
    on conflict (id) do nothing;
  insert into public.join_requests (family_id, invite_id, applicant_id)
  values (v_family, v_invite, v_applicant)
  returning id into v_request;

  -- B 家 owner 過渡期
  update public.profiles set deletion_requested_at = now() where id = v_owner;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.approve_join(v_request);
    raise exception 'FAIL：過渡期的 owner 竟然能 approve_join';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL：LS051 沒有被觸發（approve_join）';
  end if;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_applicant;
  if v_n <> 0 then
    raise exception 'FAIL：被擋下的核准竟然還是留下了 family_members 列';
  end if;

  raise notice 'ok：approve_join（過渡期 owner）被擋（LS051），沒有留下 family_members 殘餘列';
end;
$$;

rollback;
