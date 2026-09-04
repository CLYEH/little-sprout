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
-- 0. 正向對照：service_role 對 profiles 只有欄位級 SELECT（id、
--    deletion_requested_at），沒有 UPDATE、沒有整表 SELECT（LS-151 R2 grant，
--    merge-review R1 i1 收斂）
-- ===========================================================================
do $$
begin
  -- R2：改成欄位級 grant 之後 has_table_privilege 對「整表」SELECT 回 false
  -- 是正確的（Postgres 語意：has_table_privilege 只看 relacl 的表級授權，不看
  -- attacl 的欄位級授權）——用 has_column_privilege 驗證實際被開放的兩欄，並
  -- 反向確認整表層級真的沒有被開放（欄位級收斂真的生效，不是誤植成整表）。
  if not has_column_privilege('service_role', 'public.profiles', 'id', 'select') then
    raise exception 'FAIL：service_role 沒有 profiles.id 的 SELECT grant——finalize_account_deletion／EF 用 .eq("id", uid) 過濾需要這一欄的 SELECT 權限';
  end if;
  if not has_column_privilege('service_role', 'public.profiles', 'deletion_requested_at', 'select') then
    raise exception 'FAIL：service_role 沒有 profiles.deletion_requested_at 的 SELECT grant——Edge Function delete-account 讀不到這一欄';
  end if;
  if has_column_privilege('service_role', 'public.profiles', 'display_name', 'select') then
    raise exception 'FAIL：service_role 竟然對 profiles.display_name 有 SELECT grant（收斂範圍以外的欄位不該開放）';
  end if;
  if has_table_privilege('service_role', 'public.profiles', 'select') then
    raise exception 'FAIL：service_role 竟然有 profiles 的整表 SELECT grant（本票只該開 id／deletion_requested_at 兩欄，見 migration 檔頭）';
  end if;
  if has_table_privilege('service_role', 'public.profiles', 'update') then
    raise exception 'FAIL：service_role 竟然有 profiles 的 UPDATE grant（本票不需要寫 profiles，見 migration 檔頭）';
  end if;
  raise notice 'ok：service_role 對 profiles 只有欄位級 SELECT（id、deletion_requested_at），沒有整表 SELECT，沒有 UPDATE';
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
-- 6.（R2 訂正，merge-review R1 b1eb4e1d B1）approve_join（family_members
--    INSERT）：guard 現在查的是「被核准的申請人」（NEW.user_id），不是「核准者
--    自己的狀態」（auth.uid()）。R1 版本這裡原本斷言「操作者（owner）過渡期 →
--    approve_join 被擋」，B1 指出那個斷言其實是在測一個對防線沒有幫助、範圍還
--    過寬的行為——真正的風險是「被寫進 family_members 的人是過渡期使用者」，跟
--    「核准這個動作的人是不是過渡期使用者」無關（owner 自己是否過渡期，不影響
--    他自己會不會又拿到一列 family_members；他核准的是別人）。改成驗證新語意：
--    owner 本人過渡期、但要核准的申請人健康 → approve_join 必須成功；申請人過渡
--    期的情境已移到上面第 7a 段（不論核准者健康與否都要擋，那才是 B1 真正的
--    攻擊路徑）。
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

  -- B 家 owner 過渡期（核准者本人，不是被核准的人）
  update public.profiles set deletion_requested_at = now() where id = v_owner;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.approve_join(v_request);
  reset role;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_applicant;
  if v_n <> 1 then
    raise exception 'FAIL：核准者（owner）本人過渡期，但被核准的申請人健康——approve_join 應該成功，實際 family_members 列數 %', v_n;
  end if;

  raise notice 'ok：approve_join（核准者過渡期、被核准申請人健康）成功——guard 查的是被寫入的人，不是操作者';
end;
$$;

rollback;

-- ===========================================================================
-- 7.（R2，merge-review R1 b1eb4e1d B1）family_members guard 改查 NEW.user_id：
--    操作者是健康使用者、被寫入的人是過渡期使用者，三條路徑都要被擋。
-- ===========================================================================

-- 7a. 健康 owner 呼叫 approve_join()，要核准的申請人在「申請成立之後」才被標記
--     deletion_requested_at——approve_join 的 auth.uid() 是核准者（健康），INSERT
--     的 NEW.user_id 是申請人（過渡期）。R1 版本查 auth.uid() 會誤放行，R2 必須擋。
begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_invite uuid := gen_random_uuid();
  v_applicant uuid := gen_random_uuid();
  v_request uuid;
  v_n int;
  v_raised boolean := false;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7a-owner@ls151.test', now(), now(), '{}', '{}'),
    (v_applicant, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7a-applicant@ls151.test', now(), now(), '{}', '{}');

  insert into public.profiles (id, display_name) values
    (v_owner, 'LS151 R2 7a owner'),
    (v_applicant, 'LS151 R2 7a applicant')
    on conflict (id) do nothing;

  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 7a 家', v_owner);
  insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at)
  values (v_invite, v_family, 'LS151R27A', 'owner', v_owner, 3, now() + interval '7 days');

  -- 申請時 v_applicant 還健康，申請正常成立
  insert into public.join_requests (family_id, invite_id, applicant_id)
  values (v_family, v_invite, v_applicant)
  returning id into v_request;

  -- 申請成立之後才標記——模擬「申請人後來另外呼叫 delete_my_account()」，留下一筆
  -- 待審申請（finalize_account_deletion 第 1 步就是在清這種殘留）。
  update public.profiles set deletion_requested_at = now() where id = v_applicant;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.approve_join(v_request);
    raise exception 'FAIL：健康 owner 竟然能 approve_join 一個過渡期申請人';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL 7a：LS051 沒有被觸發（approve_join 過渡期申請人，核准者健康）';
  end if;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_applicant;
  if v_n <> 0 then
    raise exception 'FAIL 7a：被擋下的核准竟然還是留下了 family_members 列';
  end if;
  reset role;

  raise notice 'ok 7a：approve_join（操作者健康、被核准者過渡期）被擋（LS051）——family_members guard 正確查 NEW.user_id 而非 auth.uid()';
end;
$$;

rollback;

-- 7b. UPDATE family_members set role='owner'（既有的 owner 交接路徑）指向一個過渡
--     期使用者——操作者是健康的 owner，NEW.user_id 是過渡期使用者，B1 指出 R1 版本
--     完全沒擋（只掛在 BEFORE INSERT），R2 必須擋。
begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_member uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_raised boolean := false;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7b-owner@ls151.test', now(), now(), '{}', '{}'),
    (v_member, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7b-member@ls151.test', now(), now(), '{}', '{}');

  insert into public.profiles (id, display_name) values
    (v_owner, 'LS151 R2 7b owner'),
    (v_member, 'LS151 R2 7b member')
    on conflict (id) do nothing;

  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 7b 家', v_owner);
  insert into public.family_members (family_id, user_id, role) values (v_family, v_member, 'member');

  -- v_member 健康時已經是 member，之後才被標記過渡期
  update public.profiles set deletion_requested_at = now() where id = v_member;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.family_members set role = 'owner'
     where family_id = v_family and user_id = v_member;
    raise exception 'FAIL：健康 owner 竟然能把過渡期成員升成 owner（UPDATE role 路徑）';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL 7b：LS051 沒有被觸發（UPDATE family_members role 指向過渡期使用者）';
  end if;

  set local role postgres;
  perform 1 from public.family_members
   where family_id = v_family and user_id = v_member and role = 'member';
  if not found then
    raise exception 'FAIL 7b：被擋下的 UPDATE 竟然還是把角色改掉了';
  end if;
  reset role;

  raise notice 'ok 7b：UPDATE family_members.role 指向過渡期使用者被擋（LS051）——B1 原本完全沒擋的 UPDATE 路徑現在有 guard';
end;
$$;

rollback;

-- 7c. request_join 由過渡期使用者自己發起——B1 攻擊路徑的第一步，R2 新增的
--     join_requests guard（縱深防禦）擋在申請這一步。
begin;

do $$
declare
  v_solo uuid := gen_random_uuid();
  v_family_owner uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_code text := 'LS151R27C';  -- 自建邀請碼——B 家 fixture 碼 'LS6-BBB-INVITE' 帶連字號，
                                -- request_join 會先 regexp_replace 去掉非英數字元再比對，
                                -- 直接拿帶連字號的字面值當輸入不會命中，這裡改用自建的
                                -- 純英數碼，避免混進 fixture 正規化細節，測試意圖更乾淨。
  v_n int;
  v_raised boolean := false;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_family_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7c-owner@ls151.test', now(), now(), '{}', '{}'),
    (v_solo, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-7c@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_family_owner, 'LS151 R2 7c owner')
    on conflict (id) do nothing;
  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 7c 家', v_family_owner);
  insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at)
  values (gen_random_uuid(), v_family, v_code, 'member', v_family_owner, 3, now() + interval '7 days');

  -- private.handle_new_auth_user() 已經自動建立 profiles 列（96_ 涵蓋的 trigger），
  -- 這裡用 upsert 補標 deletion_requested_at，不是新增一列。
  insert into public.profiles (id, display_name, deletion_requested_at)
  values (v_solo, 'LS151 R2 7c 過渡期申請人', now())
    on conflict (id) do update set deletion_requested_at = excluded.deletion_requested_at;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_solo, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.request_join(v_code);
    raise exception 'FAIL：過渡期使用者竟然能 request_join';
  exception when sqlstate 'LS051' then
    v_raised := true;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL 7c：LS051 沒有被觸發（request_join 由過渡期使用者發起）';
  end if;

  set local role postgres;
  select count(*) into v_n from public.join_requests where applicant_id = v_solo;
  if v_n <> 0 then
    raise exception 'FAIL 7c：被擋下的申請竟然還是留下了 join_requests 列';
  end if;
  reset role;

  raise notice 'ok 7c：request_join 由過渡期使用者發起被擋（LS051）——join_requests guard（縱深防禦）';
end;
$$;

rollback;

-- ===========================================================================
-- 8. finalize_account_deletion(uuid)（票文選項 (b)，第一道防線）：只有
--    service_role 能執行；非唯一 owner／唯一 owner 有其他成員／唯一 owner 無其他
--    成員三種情境，各自驗證清理結果正確、清理後 delete from auth.users 不再撞
--    LS001。
-- ===========================================================================

-- 8-0. 授權對照：authenticated 呼叫不到，只有 service_role 呼叫得到——防呼叫端
--      誤用／繞過 Edge Function 直接清空自己想清的家庭。
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';  -- 健康使用者（fixtures）
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.finalize_account_deletion(v_member);
  exception when insufficient_privilege then
    v_raised := true;
  end;
  reset role;
  if not v_raised then
    raise exception 'FAIL 8-0：authenticated 竟然能呼叫 finalize_account_deletion（只該開放 service_role）';
  end if;
  raise notice 'ok 8-0：authenticated 呼叫 finalize_account_deletion 被拒（insufficient_privilege，42501）';
end;
$$;

rollback;

-- 8a. 不是唯一 owner（一般成員，家庭還有 owner 與其他成員）——直接刪除 p_user 這
--     一列，不影響家庭與其他成員。
begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_target uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8a-owner@ls151.test', now(), now(), '{}', '{}'),
    (v_target, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8a-target@ls151.test', now(), now(), '{}', '{}'),
    (v_other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8a-other@ls151.test', now(), now(), '{}', '{}');

  insert into public.profiles (id, display_name) values
    (v_owner, 'LS151 R2 8a owner'),
    (v_target, 'LS151 R2 8a target'),
    (v_other, 'LS151 R2 8a other')
    on conflict (id) do nothing;

  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 8a 家', v_owner);
  insert into public.family_members (family_id, user_id, role) values
    (v_family, v_target, 'member'),
    (v_family, v_other, 'member');

  update public.profiles set deletion_requested_at = now() where id = v_target;

  set local role service_role;
  perform public.finalize_account_deletion(v_target);
  reset role;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 8a：finalize_account_deletion 沒有刪掉非唯一 owner 的 family_members 列';
  end if;

  perform 1 from public.family_members
   where family_id = v_family and user_id = v_owner and role = 'owner';
  if not found then
    raise exception 'FAIL 8a：原 owner 的列竟然被動到了';
  end if;
  perform 1 from public.family_members
   where family_id = v_family and user_id = v_other and role = 'member';
  if not found then
    raise exception 'FAIL 8a：其他成員的列竟然被動到了';
  end if;
  perform 1 from public.families where id = v_family;
  if not found then
    raise exception 'FAIL 8a：家庭竟然被刪掉了（p_user 不是唯一 owner，不該影響家庭）';
  end if;

  -- 清理後刪除 auth.users 必須成功，不撞 LS001
  delete from auth.users where id = v_target;
  select count(*) into v_n from public.profiles where id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 8a：delete from auth.users 後 profiles 列竟然還在';
  end if;
  reset role;

  raise notice 'ok 8a：非唯一 owner——finalize_account_deletion 只刪自己那一列，家庭與其他成員不受影響，後續刪除 auth.users 成功';
end;
$$;

rollback;

-- 8b. 唯一 owner、家庭還有其他成員——升格最早加入的其他成員為 owner，再刪除
--     p_user 自己那一列；驗證升格對象確實是 created_at 最早的那一位。
begin;

do $$
declare
  v_target uuid := gen_random_uuid();
  v_earlier uuid := gen_random_uuid();
  v_later uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_n int;
  v_role public.family_role;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_target, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8b-target@ls151.test', now(), now(), '{}', '{}'),
    (v_earlier, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8b-earlier@ls151.test', now(), now(), '{}', '{}'),
    (v_later, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'ls151-r2-8b-later@ls151.test', now(), now(), '{}', '{}');

  insert into public.profiles (id, display_name) values
    (v_target, 'LS151 R2 8b target'),
    (v_earlier, 'LS151 R2 8b earlier'),
    (v_later, 'LS151 R2 8b later')
    on conflict (id) do nothing;

  -- target 是建立者，add_creator_as_owner 自動把它寫成 owner
  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 8b 家', v_target);

  -- 刻意插入順序與「最早加入」順序相反（later 先插、created_at 卻比較晚），確保
  -- 驗證的是 created_at 而不是插入順序或 user_id 字面大小
  insert into public.family_members (family_id, user_id, role, created_at) values
    (v_family, v_later, 'member', now() - interval '1 day'),
    (v_family, v_earlier, 'member', now() - interval '2 days');

  update public.profiles set deletion_requested_at = now() where id = v_target;

  set local role service_role;
  perform public.finalize_account_deletion(v_target);
  reset role;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 8b：finalize_account_deletion 沒有刪掉原 owner（target）的列';
  end if;

  select role into v_role from public.family_members
   where family_id = v_family and user_id = v_earlier;
  if v_role is distinct from 'owner' then
    raise exception 'FAIL 8b：最早加入的成員（earlier）沒有被升為 owner（實際角色 %）', v_role;
  end if;

  select role into v_role from public.family_members
   where family_id = v_family and user_id = v_later;
  if v_role is distinct from 'member' then
    raise exception 'FAIL 8b：較晚加入的成員（later）角色被誤動（實際角色 %，應維持 member）', v_role;
  end if;

  perform 1 from public.families where id = v_family;
  if not found then
    raise exception 'FAIL 8b：家庭竟然被刪掉了（升格成功、不該 cascade）';
  end if;

  delete from auth.users where id = v_target;
  select count(*) into v_n from public.profiles where id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 8b：delete from auth.users 後 profiles 列竟然還在';
  end if;
  reset role;

  raise notice 'ok 8b：唯一 owner 有其他成員——最早加入者（earlier）被升為 owner，較晚加入者不受影響，家庭仍在，後續刪除 auth.users 成功、無 LS001';
end;
$$;

rollback;

-- 8c. 唯一 owner、沒有其他成員——整個家庭連同底下資料一併刪除（cascade）。
begin;

do $$
declare
  v_target uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_target, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls151-r2-8c-target@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_target, 'LS151 R2 8c target')
    on conflict (id) do nothing;

  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 8c 家', v_target);

  update public.profiles set deletion_requested_at = now() where id = v_target;

  set local role service_role;
  perform public.finalize_account_deletion(v_target);
  reset role;

  set local role postgres;
  select count(*) into v_n from public.families where id = v_family;
  if v_n <> 0 then
    raise exception 'FAIL 8c：唯一 owner 沒有其他成員，finalize_account_deletion 竟然沒有把家庭 cascade 刪掉';
  end if;
  select count(*) into v_n from public.family_members where family_id = v_family;
  if v_n <> 0 then
    raise exception 'FAIL 8c：家庭被刪了但 family_members 竟然還有殘留列';
  end if;

  delete from auth.users where id = v_target;
  select count(*) into v_n from public.profiles where id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 8c：delete from auth.users 後 profiles 列竟然還在';
  end if;
  reset role;

  raise notice 'ok 8c：唯一 owner 沒有其他成員——finalize_account_deletion 把整個家庭 cascade 刪除，後續刪除 auth.users 成功、無 LS001';
end;
$$;

rollback;

-- ===========================================================================
-- 9. M1 收斂路徑（merge-review R1 b1eb4e1d）：guard 的 exists() 是快照讀、不取
--    鎖，READ COMMITTED 下「標記 deletion_requested_at」與「並行 INSERT」之間有
--    競態窗口，雙連線實測會被穿過。這裡不重跑雙連線時序（那只是製造這個狀態的
--    其中一種方式），直接以 service_role 身分製造這個競態「本來會產生」的殘留
--    狀態——deletion_requested_at 已標記、但使用者仍是某家庭的唯一 owner——先
--    用對照組確認「不先清理」真的會撞 LS001，再驗證 finalize_account_deletion
--    是 M1 穿過後真正的收斂路徑：不管殘留狀態是怎麼來的，呼叫它之後
--    delete from auth.users 都會成功。
-- ===========================================================================
begin;

do $$
declare
  v_target uuid := gen_random_uuid();
  v_family uuid := gen_random_uuid();
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_target, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls151-r2-m1@ls151.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_target, 'LS151 R2 M1 target')
    on conflict (id) do nothing;

  -- 製造殘留狀態：v_target 健康時期正常成為某家庭的唯一 owner（不經任何 guard，
  -- 那時候還沒標記），再標記 deletion_requested_at——這就是 M1 指出的競態「本來
  -- 會產生」的終態：guard 只擋「標記之後」的新 INSERT／UPDATE，擋不住標記之前
  -- 就已經存在的成員關係。
  insert into public.families (id, name, created_by) values (v_family, 'LS151 R2 M1 家', v_target);
  update public.profiles set deletion_requested_at = now() where id = v_target;

  -- 對照組：模擬 Edge Function 直接呼叫 service_role 執行
  -- `delete from auth.users`，但*沒有*先呼叫 finalize_account_deletion——重現
  -- B1／M1 修復前的失敗，順便確認這個測試前提本身站得住腳。
  begin
    delete from auth.users where id = v_target;
    raise exception 'FAIL 9：對照組——沒有先清理竟然沒有撞見 LS001（測試前提本身有問題）';
  exception when sqlstate 'LS001' then
    null;  -- 預期：家庭必須至少保留一位 owner，v_target 是唯一 owner
  end;

  -- 上面的 DELETE 因為 LS001 已整句回滾（PL/pgSQL 例外區塊＝隱含 SAVEPOINT），
  -- families／profiles.deletion_requested_at 都還在，重新走一次真正的流程。
  set local role service_role;
  perform public.finalize_account_deletion(v_target);
  reset role;

  delete from auth.users where id = v_target;
  select count(*) into v_n from public.profiles where id = v_target;
  if v_n <> 0 then
    raise exception 'FAIL 9：finalize_account_deletion 之後刪除 auth.users 仍然沒有清乾淨 profiles';
  end if;
  select count(*) into v_n from public.families where id = v_family;
  if v_n <> 0 then
    raise exception 'FAIL 9：finalize_account_deletion 之後家庭竟然還在（唯一 owner 沒有其他成員，應該被 cascade）';
  end if;
  reset role;

  raise notice 'ok 9：M1 收斂路徑——已標記＋仍是唯一 owner 的殘留狀態，不先清理會撞 LS001（對照組確認），呼叫 finalize_account_deletion 之後刪除 auth.users 成功';
end;
$$;

rollback;

-- ===========================================================================
-- 10. 結構性斷言（minor-6，比照 96_profiles_auto_create.sql §7 的做法）：mutation
--     矩陣實測發現 families_deletion_guard 被拿掉後 92_ 仍然全綠（下游
--     add_creator_as_owner 的 family_members INSERT 會先擋下來，兩支 trigger 的
--     效果從行為測試上無法區分）——不靠「行為測試碰巧測不到」推論這支 trigger
--     還在，直接查 catalog 釘住每一支 guard trigger 的存在、掛的表、掛的函式、
--     是否啟用；一併釘住 finalize_account_deletion 的 SECURITY DEFINER 與
--     EXECUTE 只開放 service_role。
-- ===========================================================================
do $$
declare
  v_expected jsonb := '[
    {"table": "families", "trigger": "families_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "family_members", "trigger": "family_members_deletion_guard", "fn": "enforce_family_member_write_not_deletion_requested"},
    {"table": "media", "trigger": "media_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "diaries", "trigger": "diaries_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "albums", "trigger": "albums_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "children", "trigger": "children_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "comments", "trigger": "comments_deletion_guard", "fn": "enforce_account_not_deletion_requested"},
    {"table": "join_requests", "trigger": "join_requests_deletion_guard", "fn": "enforce_join_request_not_deletion_requested"}
  ]'::jsonb;
  v_item jsonb;
  v_tgenabled "char";
  v_actual_fn text;
begin
  for v_item in select * from jsonb_array_elements(v_expected)
  loop
    v_tgenabled := null;
    v_actual_fn := null;

    select t.tgenabled, p.proname into v_tgenabled, v_actual_fn
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc p on p.oid = t.tgfoid
     where n.nspname = 'public'
       and c.relname = v_item->>'table'
       and t.tgname = v_item->>'trigger';

    if v_tgenabled is null then
      raise exception 'FAIL：找不到 % 上的 trigger %', v_item->>'table', v_item->>'trigger';
    end if;
    if v_tgenabled = 'D' then
      raise exception 'FAIL：trigger % 被停用（tgenabled=D）', v_item->>'trigger';
    end if;
    if v_actual_fn is distinct from v_item->>'fn' then
      raise exception 'FAIL：trigger % 掛的函式是 %，應該是 %', v_item->>'trigger', v_actual_fn, v_item->>'fn';
    end if;
  end loop;

  raise notice 'ok：8 支過渡期擋寫 trigger（含 R2 新增的 family_members／join_requests 專用版）皆存在、啟用、掛對函式';
end;
$$;

do $$
declare
  v_prosecdef boolean;
  v_execute_service boolean;
  v_execute_authenticated boolean;
begin
  select p.prosecdef into v_prosecdef
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'finalize_account_deletion';
  if v_prosecdef is not true then
    raise exception 'FAIL：public.finalize_account_deletion 必須是 SECURITY DEFINER';
  end if;

  select has_function_privilege('service_role', 'public.finalize_account_deletion(uuid)', 'execute')
    into v_execute_service;
  select has_function_privilege('authenticated', 'public.finalize_account_deletion(uuid)', 'execute')
    into v_execute_authenticated;

  if not v_execute_service then
    raise exception 'FAIL：service_role 對 finalize_account_deletion 沒有 EXECUTE';
  end if;
  if v_execute_authenticated then
    raise exception 'FAIL：authenticated 竟然對 finalize_account_deletion 有 EXECUTE（只該開放 service_role）';
  end if;

  raise notice 'ok：finalize_account_deletion 是 SECURITY DEFINER，EXECUTE 只開放 service_role';
end;
$$;
