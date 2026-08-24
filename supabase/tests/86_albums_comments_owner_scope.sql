-- LS-52 — albums_update／comments_update owner 分支不限欄位收斂驗收
--
-- 對應 20260825010000_albums_comments_owner_scope.sql 的每一項決定。角色矩陣沿用
-- 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3；額外在各段自己的交易內
-- 加一位「A 家第 4 位成員」a4（非作者、非 owner 的 member，權限矩陣需要這個角色，
-- fixtures 沒有現成的）；非本家庭成員用 B 家 owner（b1）代表。每段各自 begin/rollback，
-- 互不依賴前一段留下的狀態。
--
-- 斷言依據標註慣例（LS-15 review round 2 定下）沿用：每段標明是靠本票的 migration
-- 保證，還是靠既有（LS-6）的既有行為。
--
-- ---------------------------------------------------------------------------
-- Mutation 自證（開發期用本機 Supabase CLI 映像手動驗證，非本檔自動執行）：
--   M1：拿掉 migration 裡的兩句 ALTER POLICY（policy 維持收斂前的 owner 分支）
--       → 下面 §A 的「owner 直接 UPDATE 別人相簿 title 應影響 0 列」斷言變紅
--         （owner 分支還在，row_count 變成 1，title 真的被改掉）。
--   M2：把 set_album_deleted 的 UPDATE 多加一句 `title = 'HACKED'`
--       → 下面 §B「owner 軟刪別人相簿後 title 必須逐字不變」的斷言變紅。
--   M3：拿掉 set_album_deleted 裡的 `if not v_is_owner and (...) then raise ...`
--       授權檢查 → 下面 §B「viewer 軟刪別人相簿必須 42501」的斷言變紅。
-- 三個 mutation 都個別驗證過（各自單獨套用、其餘保持修好的版本），確認會讓對應
-- 的斷言、且只有對應的斷言，從綠變紅——不是整份測試檔一起爛掉的那種假陽性。
-- comments 側（set_comment_deleted）用同一支函式骨架，未重複列出對應的 M1'/M2'/M3'。
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on

-- ===========================================================================
-- §A. albums：直接 UPDATE 改內容（title）——只有作者本人放行，其餘角色一律
--     影響 0 列、內容逐字不變（USING 比對不上、Postgres 靜默排除，非 raise；
--     這是 migration 檔案本身已經解釋過的 Postgres RLS 標準行為，不是 bug）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';  -- member，本段的作者
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';  -- 額外加的 A 家第 4 位成員
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_album uuid;
  v_title text;
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員');
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.albums (family_id, title, created_by)
  values (v_family, '原始標題', v_author)
  returning id into v_album;
  reset role;

  -- 作者本人：直接 UPDATE 放行（既有行為，本票未動）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = '作者改過的標題' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：作者本人直接 UPDATE 自己的相簿 title 應該成功，實際影響 % 列', v_n;
  end if;
  raise notice 'ok：作者本人可以直接 UPDATE 自己相簿的 title';

  -- 下面每個負向角色都重複同一個判準：0 列、title 逐字不變。
  -- owner（非作者）——本票要修的核心洞：收斂前這裡會是 1 列且 title 被改掉。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'owner 竄改的標題' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  select title into v_title from public.albums where id = v_album;
  if v_n <> 0 or v_title <> '作者改過的標題' then
    raise exception 'FAIL：owner（非作者）直接 UPDATE 別人相簿的 title 竟然生效了（影響 % 列，title=「%」）——LS-52 要修的洞沒有補上', v_n, v_title;
  end if;
  raise notice 'ok：owner（非作者）直接 UPDATE 別人相簿的 title 影響 0 列，內容逐字不變';

  -- member（非作者、非 owner）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'member 竄改的標題' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  select title into v_title from public.albums where id = v_album;
  if v_n <> 0 or v_title <> '作者改過的標題' then
    raise exception 'FAIL：非作者的 member 竟然改得動別人的相簿 title（影響 % 列，title=「%」）', v_n, v_title;
  end if;

  -- viewer
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = 'viewer 竄改的標題' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：viewer 竟然改得動相簿 title（影響 % 列）', v_n;
  end if;

  -- 非本家庭成員
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = '外人竄改的標題' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：非本家庭成員竟然改得動相簿 title（影響 % 列）', v_n;
  end if;
  raise notice 'ok：member（非作者）／viewer／非本家庭成員 對相簿 title 的直接 UPDATE 皆影響 0 列';

  -- 作者已離開家庭：完全不在 family_members 裡了
  delete from public.family_members where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = '離開後想改' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  select title into v_title from public.albums where id = v_album;
  if v_n <> 0 or v_title <> '作者改過的標題' then
    raise exception 'FAIL：已離開家庭的前作者竟然還改得動自己過去建立的相簿（影響 % 列）', v_n;
  end if;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法直接 UPDATE 自己過去建立的相簿';

  -- 作者被降級成 viewer：仍在 family_members，但不再是 contributor
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.albums set title = '降級後想改' where id = v_album;
  get diagnostics v_n = row_count;
  reset role;
  select title into v_title from public.albums where id = v_album;
  if v_n <> 0 or v_title <> '作者改過的標題' then
    raise exception 'FAIL：被降級成 viewer 的前作者竟然還改得動自己過去建立的相簿（影響 % 列）', v_n;
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的前作者無法直接 UPDATE 自己過去建立的相簿（albums 的作者分支要求仍是 contributor，跟收斂前一致，不是本票新加的限制）';
end;
$$;

rollback;

-- ===========================================================================
-- §B. albums：set_album_deleted 角色矩陣——owner 對別人相簿唯一剩下的操作
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_album uuid;
  v_title_before text;
  v_deleted_at timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員');
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.albums (family_id, title, created_by)
  values (v_family, '會被軟刪又還原的相簿', v_author)
  returning id into v_album;
  reset role;

  -- 作者本人（仍是 contributor）：軟刪／還原自己的
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：作者軟刪自己的相簿沒有生效';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, false);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is not null then
    raise exception 'FAIL：作者還原自己的相簿沒有生效';
  end if;
  raise notice 'ok：作者本人可以用 set_album_deleted 軟刪／還原自己的相簿';

  -- owner（非作者）：軟刪別人的——這是 §10 授權的那件事，且只動 deleted_at
  select title into v_title_before from public.albums where id = v_album;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 用 set_album_deleted 軟刪別人的相簿沒有生效';
  end if;
  if (select title from public.albums where id = v_album) is distinct from v_title_before then
    raise exception 'FAIL：owner 軟刪別人的相簿時，title 被改動了（從「%」變成「%」）——set_album_deleted 不該碰得到內容欄位',
      v_title_before, (select title from public.albums where id = v_album);
  end if;
  raise notice 'ok：owner 可以用 set_album_deleted 軟刪別人的相簿，且 title 逐字不變';

  -- member（非作者、非 owner）：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：非作者、非 owner 的 member 竟然可以用 set_album_deleted 動別人的相簿';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  -- viewer：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：viewer 竟然可以用 set_album_deleted 動相簿';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  -- 非本家庭成員：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：非本家庭成員竟然可以用 set_album_deleted 動相簿';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  raise notice 'ok：非作者非 owner 的 member／viewer／非本家庭成員呼叫 set_album_deleted 皆 42501';

  -- 作者已離開家庭：連軟刪自己過去建立的都不行（跟直接 UPDATE 的判準一致）
  delete from public.family_members where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：已離開家庭的前作者竟然還能用 set_album_deleted 動自己過去建立的相簿';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法用 set_album_deleted 動自己過去建立的相簿';

  -- 作者被降級成 viewer：同樣不行——這支 RPC 的作者分支判準逐字沿用收斂前
  -- albums_update 作者分支的判準（要求仍是 contributor），跟 diaries 的
  -- set_diary_deleted（作者分支只要求仍是任何角色的成員）刻意不同，見 migration
  -- 說明；這裡驗證的正是「albums 沒有比照 diaries 放寬」這件事。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：被降級成 viewer 的前作者竟然還能用 set_album_deleted 動自己過去建立的相簿';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的前作者無法用 set_album_deleted 動自己過去建立的相簿（要求仍是 contributor，非本票新加限制）';

  -- 不存在的相簿 → LS023
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(gen_random_uuid(), true);
    raise exception 'FAIL：軟刪不存在的相簿竟然沒有出錯';
  exception when sqlstate 'LS023' then
    null;
  end;
  reset role;
  raise notice 'ok：set_album_deleted 對不存在的相簿回報 LS023';
end;
$$;

rollback;

-- ===========================================================================
-- §C. comments：直接 UPDATE 改內容（body）——只有作者本人放行；作者分支的判準
--     是「仍是該家庭任一角色的成員」（family_ids()，不是 contributor_family_ids()，
--     跟 albums 不同——viewer 也能留言，PLAN §3），這是收斂前就有的既有行為，
--     本段連帶驗證這個差異點沒有被本票夾帶抹平
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_target_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_comment uuid;
  v_body text;
  v_n int;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員');
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (v_family, 'media', v_target_media, v_author, '原始留言')
  returning id into v_comment;
  reset role;

  -- 作者本人：放行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = '作者改過的留言' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：作者本人直接 UPDATE 自己的留言 body 應該成功，實際影響 % 列', v_n;
  end if;
  raise notice 'ok：作者本人可以直接 UPDATE 自己的留言 body';

  -- owner（非作者）——本票要修的核心洞
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = 'owner 竄改的留言' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  select body into v_body from public.comments where id = v_comment;
  if v_n <> 0 or v_body <> '作者改過的留言' then
    raise exception 'FAIL：owner（非作者）直接 UPDATE 別人留言的 body 竟然生效了（影響 % 列，body=「%」）——LS-52 要修的洞沒有補上', v_n, v_body;
  end if;
  raise notice 'ok：owner（非作者）直接 UPDATE 別人留言的 body 影響 0 列，內容逐字不變';

  -- member（非作者、非 owner）／viewer（非作者）／非本家庭成員：皆 0 列
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = 'member 竄改的留言' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：非作者的 member 竟然改得動別人的留言（影響 % 列）', v_n;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = 'viewer 竄改的留言' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：非作者的 viewer 竟然改得動別人的留言（影響 % 列）', v_n;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = '外人竄改的留言' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：非本家庭成員竟然改得動留言（影響 % 列）', v_n;
  end if;
  raise notice 'ok：非作者的 member／viewer／非本家庭成員 對留言 body 的直接 UPDATE 皆影響 0 列';

  -- 作者已離開家庭：不在 family_ids() 裡了，不能再改
  delete from public.family_members where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = '離開後想改' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  select body into v_body from public.comments where id = v_comment;
  if v_n <> 0 or v_body <> '作者改過的留言' then
    raise exception 'FAIL：已離開家庭的前作者竟然還改得動自己過去的留言（影響 % 列）', v_n;
  end if;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法直接 UPDATE 自己過去的留言';

  -- 作者被降級成 viewer：comments 的作者分支只要求「仍是任一角色的成員」
  -- （family_ids()），跟 albums（要求仍是 contributor）不同——這裡刻意驗證
  -- 「仍可編輯」，不是漏測負向案例。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = '降級後仍可改' where id = v_comment;
  get diagnostics v_n = row_count;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：被降級成 viewer 的前作者應該仍可編輯自己的留言（comments 作者分支只要求仍是成員），實際影響 % 列', v_n;
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的前作者仍可直接 UPDATE 自己的留言 body（comments_update 作者分支只要求仍是任一角色的成員，跟收斂前一致，不是本票放寬）';
end;
$$;

rollback;

-- ===========================================================================
-- §D. comments：set_comment_deleted 角色矩陣——owner 對別人留言唯一剩下的操作
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_target_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_comment uuid;
  v_body_before text;
  v_deleted_at timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員');
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (v_family, 'media', v_target_media, v_author, '會被軟刪又還原的留言')
  returning id into v_comment;
  reset role;

  -- 作者本人（仍是任一角色成員）：軟刪／還原自己的
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is null then
    raise exception 'FAIL：作者軟刪自己的留言沒有生效';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, false);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is not null then
    raise exception 'FAIL：作者還原自己的留言沒有生效';
  end if;
  raise notice 'ok：作者本人可以用 set_comment_deleted 軟刪／還原自己的留言';

  -- owner（非作者）：軟刪別人的，只動 deleted_at
  select body into v_body_before from public.comments where id = v_comment;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 用 set_comment_deleted 軟刪別人的留言沒有生效';
  end if;
  if (select body from public.comments where id = v_comment) is distinct from v_body_before then
    raise exception 'FAIL：owner 軟刪別人的留言時，body 被改動了（從「%」變成「%」）——set_comment_deleted 不該碰得到內容欄位',
      v_body_before, (select body from public.comments where id = v_comment);
  end if;
  raise notice 'ok：owner 可以用 set_comment_deleted 軟刪別人的留言，且 body 逐字不變';

  -- member（非作者、非 owner）／viewer（非作者）／非本家庭成員：皆 42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(v_comment, false);
    raise exception 'FAIL：非作者、非 owner 的 member 竟然可以用 set_comment_deleted 動別人的留言';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(v_comment, false);
    raise exception 'FAIL：非作者的 viewer 竟然可以用 set_comment_deleted 動別人的留言';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(v_comment, false);
    raise exception 'FAIL：非本家庭成員竟然可以用 set_comment_deleted 動留言';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  raise notice 'ok：非作者非 owner 的 member／viewer／非本家庭成員呼叫 set_comment_deleted 皆 42501';

  -- 作者已離開家庭：連軟刪自己過去的留言都不行
  delete from public.family_members where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(v_comment, false);
    raise exception 'FAIL：已離開家庭的前作者竟然還能用 set_comment_deleted 動自己過去的留言';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法用 set_comment_deleted 動自己過去的留言';

  -- 作者被降級成 viewer：仍可軟刪／還原自己的（跟直接 UPDATE 的判準一致，
  -- comments 的作者分支只要求仍是任一角色的成員）
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, false);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is not null then
    raise exception 'FAIL：被降級成 viewer 的前作者，用 set_comment_deleted 還原自己的留言卻沒有生效';
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的前作者仍可用 set_comment_deleted 軟刪／還原自己的留言（作者分支只要求仍是任一角色的成員，跟直接 UPDATE 一致）';

  -- 不存在的留言 → LS024
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(gen_random_uuid(), true);
    raise exception 'FAIL：軟刪不存在的留言竟然沒有出錯';
  exception when sqlstate 'LS024' then
    null;
  end;
  reset role;
  raise notice 'ok：set_comment_deleted 對不存在的留言回報 LS024';
end;
$$;

rollback;

-- ===========================================================================
-- §E. 授權兩層對帳
--
-- 這次的收斂**沒有**動 albums／comments 的表級 grant（跟 LS-48 對 diaries 整個
-- revoke 不同——這裡作者仍走直接 UPDATE，grant 本來就該留著）。所以這裡驗的是
-- 正向回歸：grant 這一層原封不動還在，縮權完全是靠上面兩段驗過的 policy 窄化，
-- 不是靠關掉 grant；另外驗新增兩支 RPC 的 EXECUTE 授權（authenticated 可、
-- anon 不可），這兩支也要納入 supabase/tests/60_default_privileges.sql §8 的
-- public RPC 白名單，否則會被那邊「清單外函式」那段擋下——本檔已同步更新那個
-- 白名單，這裡不重複驗 definer／search_path 硬化（60_ 已經涵蓋）。
-- ---------------------------------------------------------------------------
do $$
begin
  if not has_table_privilege('authenticated', 'public.albums', 'update') then
    raise exception 'FAIL 回歸：authenticated 失去 albums 的表級 UPDATE grant——作者直接編輯內容的路徑會跟著壞掉';
  end if;
  if not has_table_privilege('authenticated', 'public.albums', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 albums 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.albums', 'insert') then
    raise exception 'FAIL 回歸：authenticated 失去 albums 的 INSERT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.albums', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 albums 的 DELETE grant（owner 硬刪的路徑）';
  end if;

  if not has_table_privilege('authenticated', 'public.comments', 'update') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的表級 UPDATE grant——作者直接編輯內容的路徑會跟著壞掉';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'insert') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 INSERT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 DELETE grant（owner 硬刪的路徑）';
  end if;
  raise notice 'ok 回歸：albums／comments 的 SELECT/INSERT/UPDATE/DELETE 表級 grant 原封不動——LS-52 完全靠 policy 窄化與新 RPC 達成縮權，沒有動 grant';

  if not has_function_privilege('authenticated', 'public.set_album_deleted(uuid, boolean)', 'execute') then
    raise exception 'FAIL：authenticated 不能執行 set_album_deleted，owner 軟刪別人相簿的唯一路徑會炸掉';
  end if;
  if has_function_privilege('anon', 'public.set_album_deleted(uuid, boolean)', 'execute') then
    raise exception 'FAIL：anon 竟然可以執行 set_album_deleted';
  end if;

  if not has_function_privilege('authenticated', 'public.set_comment_deleted(uuid, boolean)', 'execute') then
    raise exception 'FAIL：authenticated 不能執行 set_comment_deleted，owner 軟刪別人留言的唯一路徑會炸掉';
  end if;
  if has_function_privilege('anon', 'public.set_comment_deleted(uuid, boolean)', 'execute') then
    raise exception 'FAIL：anon 竟然可以執行 set_comment_deleted';
  end if;
  raise notice 'ok：set_album_deleted／set_comment_deleted 對 authenticated 可執行、對 anon 不可執行';
end;
$$;
