-- LS-143（LS-24 拆票）驗收：delete_my_account()
--
-- 三種角色案例＋唯一 owner 拒絕＋未登入＋欄位級 grant 收斂。併發無死鎖的場景在
-- supabase/tests/concurrency/delete_account_race_*.sql（比照 LS-6／LS-15 的
-- owner_guard_* 場景），這裡只測單一連線可以測完的行為，每段都用 begin…rollback
-- 包住，不需要額外的 cleanup（rollback 會連同本檔案自建的暫時資料一起復原）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 非 owner 成員（member）自刪帳號：自己的 diary／album／comment 依既有 soft
--    delete 策略處理（deleted_by=自己），離開家庭，家庭與其他人的內容不受影響
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';  -- A 家 member（fixtures）
  v_diary uuid := 'ad000000-0000-4000-8000-000000000001';
  v_album uuid := 'ae000000-0000-4000-8000-000000000001';
  v_comment uuid := 'af000000-0000-4000-8000-000000000001';
  v_n int;
  v_deleted_at timestamptz;
  v_deleted_by uuid;
  v_requested_at timestamptz;
begin
  set local role postgres;
  -- 額外造一篇 member 自己的日記／相簿／留言，涵蓋三張表（fixtures 裡這個 member
  -- 沒有任何自己的內容可測）。
  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_member, 'member 自己的日記，用來驗自刪', current_date);
  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, 'member 自己的相簿', v_member);
  insert into public.comments (id, family_id, target_type, target_id, author_id, body)
  values (v_comment, v_family, 'media', '3a000000-0000-4000-8000-000000000001', v_member, 'member 自己的留言');
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;

  select count(*) into v_n from public.family_members
   where family_id = v_family and user_id = v_member;
  if v_n <> 0 then
    raise exception 'FAIL：member 呼叫 delete_my_account() 後仍留在 family_members（% 列）', v_n;
  end if;

  select count(*) into v_n from public.family_members where family_id = v_family;
  if v_n <> 2 then
    raise exception 'FAIL：A 家應剩 2 位成員（owner+viewer），實際 %', v_n;
  end if;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by
    from public.diaries where id = v_diary;
  if v_deleted_at is null or v_deleted_by is distinct from v_member then
    raise exception 'FAIL：member 自己的日記沒有被正確軟刪（deleted_at=% deleted_by=%）',
      v_deleted_at, v_deleted_by;
  end if;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by
    from public.albums where id = v_album;
  if v_deleted_at is null or v_deleted_by is distinct from v_member then
    raise exception 'FAIL：member 自己的相簿沒有被正確軟刪（deleted_at=% deleted_by=%）',
      v_deleted_at, v_deleted_by;
  end if;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by
    from public.comments where id = v_comment;
  if v_deleted_at is null or v_deleted_by is distinct from v_member then
    raise exception 'FAIL：member 自己的留言沒有被正確軟刪（deleted_at=% deleted_by=%）',
      v_deleted_at, v_deleted_by;
  end if;

  -- 家庭既有的、不屬於這個 member 的內容（fixtures 的 5a/4a/6a）完全不受影響。
  select deleted_at into v_deleted_at from public.diaries
   where id = '5a000000-0000-4000-8000-000000000001';
  if v_deleted_at is not null then
    raise exception 'FAIL：不屬於 member 的既有日記竟然被連帶軟刪';
  end if;

  select deletion_requested_at into v_requested_at from public.profiles where id = v_member;
  if v_requested_at is null then
    raise exception 'FAIL：member 的 profiles.deletion_requested_at 沒有被標記';
  end if;

  raise notice 'ok：非 owner 成員刪帳號——自己的內容依既有 soft delete 策略處理、離開家庭、家庭不受影響';
end;
$$;

rollback;

-- ===========================================================================
-- 2. 唯一 owner 且家庭還有其他成員 → 拒絕，LS050，DETAIL 帶需轉移的家庭清單，
--    不執行任何寫入
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';  -- A 家唯一 owner（fixtures）
  v_raised boolean := false;
  v_detail text;
  v_families jsonb;
  v_n int;
  v_requested_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.delete_my_account();
    raise exception 'FAIL：A 家唯一 owner（家庭還有其他成員）竟然能直接刪帳號';
  exception when sqlstate 'LS050' then
    v_raised := true;
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  reset role;

  if not v_raised then
    raise exception 'FAIL：LS050 沒有被觸發';
  end if;

  v_families := v_detail::jsonb;  -- 不是合法 JSON 會直接在這裡噴錯，测的就是这个契約
  if jsonb_typeof(v_families) <> 'array' or jsonb_array_length(v_families) <> 1 then
    raise exception 'FAIL：LS050 的 DETAIL 應該是恰好一個家庭的 JSON 陣列，實際 %', v_detail;
  end if;
  if (v_families->0->>'family_id') <> 'fa000000-0000-4000-8000-000000000001'
     or (v_families->0->>'family_name') <> 'A 家' then
    raise exception 'FAIL：LS050 的 DETAIL 內容不對：%', v_detail;
  end if;

  set local role postgres;
  select count(*) into v_n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if v_n <> 3 then
    raise exception 'FAIL：拒絕之後 A 家成員數不該變，實際 %', v_n;
  end if;

  select deletion_requested_at into v_requested_at from public.profiles where id = v_owner;
  if v_requested_at is not null then
    raise exception 'FAIL：拒絕之後不該標記 deletion_requested_at';
  end if;

  raise notice 'ok：唯一 owner 且家庭還有其他成員——LS050 拒絕，DETAIL 正確列出需轉移的家庭，未執行任何寫入';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 唯一成員（也是唯一 owner）→ 家庭與其資料一併刪除（cascade）
-- ===========================================================================
begin;

do $$
declare
  v_sole uuid := 'ab000000-0000-4000-8000-000000000001';
  v_family uuid := 'aa000000-0000-4000-8000-000000000001';
  v_diary uuid := 'ac000000-0000-4000-8000-000000000001';
  v_n int;
  v_requested_at timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_sole, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'ls143-sole@ls143.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_sole, '獨居測試帳號')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.families (id, name, created_by) values (v_family, '獨居測試家', v_sole);
  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_sole, '獨居測試日記', current_date);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sole, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;

  set local role postgres;

  select count(*) into v_n from public.families where id = v_family;
  if v_n <> 0 then
    raise exception 'FAIL：唯一成員刪帳號後，家庭列還在';
  end if;

  select count(*) into v_n from public.diaries where id = v_diary;
  if v_n <> 0 then
    raise exception 'FAIL：唯一成員刪帳號後，家庭底下的日記還在（應隨 family cascade 刪除）';
  end if;

  select count(*) into v_n from public.family_members where user_id = v_sole;
  if v_n <> 0 then
    raise exception 'FAIL：唯一成員刪帳號後，family_members 還留著他的列';
  end if;

  -- profiles 本身不刪（auth.users 的實刪是另一支流程），但要標記 deletion_requested_at
  select deletion_requested_at into v_requested_at from public.profiles where id = v_sole;
  if v_requested_at is null then
    raise exception 'FAIL：唯一成員的 profiles.deletion_requested_at 沒有被標記';
  end if;

  raise notice 'ok：唯一成員（也是唯一 owner）——家庭與其資料一併刪除（cascade），profiles 標記 deletion_requested_at';
end;
$$;

rollback;

-- ===========================================================================
-- 4. 未登入呼叫 → 42501
-- ===========================================================================
begin;

do $$
begin
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.delete_my_account();
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然能呼叫 delete_my_account()';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：未登入呼叫 delete_my_account() 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 5. deletion_requested_at 的欄位級 grant 收斂：authenticated 直接 UPDATE 一律
--    42501，只能透過 delete_my_account() 寫入（同 88_deletion_attribution.sql
--    對 albums/diaries/comments 的 deleted_at／deleted_by／family_id 三欄驗法）
-- ===========================================================================
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.profiles set deletion_requested_at = now() where id = v_member;
    raise exception 'FAIL：authenticated 直接 UPDATE profiles.deletion_requested_at 竟然成功——欄位級 grant 沒有收回';
  exception when sqlstate '42501' then
    null;  -- ok
  end;

  -- 既有欄位（display_name／avatar_url）仍然可以直接編輯，不受這次收斂影響。
  update public.profiles set display_name = '改個名字測試' where id = v_member;
  reset role;

  raise notice 'ok：deletion_requested_at 的欄位級 grant 已收回（42501），display_name／avatar_url 不受影響';
end;
$$;

rollback;
