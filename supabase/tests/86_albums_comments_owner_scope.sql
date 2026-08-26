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
-- Mutation 自證（開發期用本機 Supabase CLI 映像實跑 `supabase db reset` +
-- `supabase/tests/run.sh` 手動驗證，非本檔自動執行；merge-reviewer PR #70
-- review F1 抓到第一版的 M2 宣稱不成立——baseline 當時在作者的兩次自我呼叫「之後」
-- 才擷取，同一個被 mutation 污染的函式先污染了 baseline 本身，後面的比對變成
-- 拿被污染的值互相比對，假綠。下面四個 mutation 已針對修好的版本重新逐一單獨
-- 套用、重跑，確認全部真的變紅）：
--   M1：拿掉 migration 裡的兩句 ALTER POLICY（policy 維持收斂前的 owner 分支）
--       → §A「owner 直接 UPDATE 別人相簿 title 應影響 0 列」斷言變紅（owner 分支
--         還在，row_count 變成 1，title 真的被改掉）。
--   M2：把 set_album_deleted 尾端的 UPDATE 多加一句 `title = 'HACKED...'`
--       → §B「作者軟刪自己的相簿時，deleted_at 以外的欄位被動到了」斷言變紅——
--         baseline 修好之後，這個斷言在**作者自己的第一次呼叫**就抓到了，不必
--         等到 owner 那一段才發現，比第一版的宣稱涵蓋更早、更嚴格。
--   M2′：comments 版本（`set_comment_deleted` 尾端多加一句 `body = 'HACKED...'`）
--       → §D 同樣在作者自己的第一次呼叫就變紅，且只有 §D 變紅、§A/§B/§C 依然
--         全線通過（mutation 精準命中 comments，沒有連坐 albums 那一側）。
--   M3：拿掉 set_album_deleted 裡的 `if not v_is_owner and (...) then raise ...`
--       授權檢查 → §B「非作者、非 owner 的 member 竟然可以用 set_album_deleted
--       動別人的相簿」斷言變紅。
-- 四個 mutation 都各自單獨套用（其餘保持修好的版本）、跑 `supabase db reset` 套用
-- 到真實 schema、再跑 `run.sh` 全套，確認每次都精準命中對應斷言、其餘斷言正常
-- 通過——不是整份測試檔一起爛掉的那種假陽性。
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
  -- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
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

  -- F3（merge-reviewer PR #70 review；LS-57 R2 起行為改變，見下）：owner 直接
  -- UPDATE 的目標欄位換成 deleted_at。R1 及之前：USING 比對不上這一列（owner
  -- 不是建立者），影響 0 列、不噴錯——deleted_at 當時對 authenticated 還是整表
  -- grant 的一部分，能到達 RLS 判斷。LS-57 R2（N1/N2 根治）之後：deleted_at／
  -- deleted_by／family_id 三欄對 authenticated 已無 UPDATE 欄位級 grant，不論
  -- 呼叫者是誰、改的是不是自己的相簿，這句 UPDATE 在到達 RLS 之前就先在 grant
  -- 層被拒絕，明確拿到 42501，不再是「靜默 0 列」——docs/API.md §2 的例外說明
  -- 已同步改寫（限縮到內容欄位），這裡補機械驗證這個行為變化，不只是文件宣稱。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.albums set deleted_at = now() where id = v_album;
    raise exception 'FAIL：owner 直接 UPDATE 別人相簿的 deleted_at 竟然成功了——deleted_at 的欄位級 grant 沒有收回';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  if (select deleted_at from public.albums where id = v_album) is not null then
    raise exception 'FAIL：owner 直接 UPDATE 別人相簿的 deleted_at 竟然真的寫入了';
  end if;
  raise notice 'ok：owner 直接 UPDATE 別人相簿的 deleted_at 一律 42501（欄位級 grant 收回，LS-57 R2）——F3 回歸，行為已從「靜默 0 列」改為明確錯誤';

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
  v_child uuid := '2a000000-0000-4000-8000-000000000001';  -- fixture：A 家的孩子
  v_cover uuid := '3a000000-0000-4000-8000-000000000001';  -- fixture：A 家的一張照片
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_album uuid;
  v_snapshot jsonb;
  v_deleted_at timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  -- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  -- F1（merge-reviewer PR #70 review）：child_id／cover_media_id 刻意塞非 NULL 值
  -- （收斂前的 fixture 沒帶這兩欄，「RPC 只寫 deleted_at」的斷言因此測不到這兩欄
  -- 被動過——這裡補上，讓下面的整列比對真的涵蓋 albums 全部可能被竄改的欄位）。
  insert into public.albums (family_id, title, child_id, cover_media_id, created_by)
  values (v_family, '會被軟刪又還原的相簿', v_child, v_cover, v_author)
  returning id into v_album;

  -- F1：baseline 必須在任何 RPC 呼叫之前擷取（INSERT 之後立刻拍照），不能在作者
  -- 自己的 set_album_deleted 呼叫「之後」才拍——reviewer 重放 mutation（RPC 多寫
  -- `title = 'HACKED'`）證實：若 baseline 晚於作者的兩次自我呼叫才擷取，作者那兩次
  -- 呼叫已經先被同一個被竄改的函式污染過 title，baseline 拍到的就已經是「HACKED」，
  -- 後面拿 owner 那次的結果去跟這個已經被污染的 baseline 比對，兩邊相等、斷言假綠。
  -- 用 `to_jsonb(row) - 'deleted_at'` 整列比對（而不是隻列舉 title 一欄）：日後這
  -- 兩張表加新欄位會自動被涵蓋，不必回頭記得在這裡加一行新的欄位比對。
  select to_jsonb(a) - 'deleted_at' - 'deleted_by' into v_snapshot from public.albums a where a.id = v_album;
  reset role;

  -- 作者本人（仍是家庭成員）：軟刪／還原自己的
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：作者軟刪自己的相簿沒有生效';
  end if;
  if (select to_jsonb(a) - 'deleted_at' - 'deleted_by' from public.albums a where a.id = v_album)
     is distinct from v_snapshot then
    raise exception 'FAIL：作者軟刪自己的相簿時，deleted_at 以外的欄位被動到了';
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
  if (select to_jsonb(a) - 'deleted_at' - 'deleted_by' from public.albums a where a.id = v_album)
     is distinct from v_snapshot then
    raise exception 'FAIL：作者還原自己的相簿時，deleted_at 以外的欄位被動到了';
  end if;
  raise notice 'ok：作者本人可以用 set_album_deleted 軟刪／還原自己的相簿，且 title/child_id/cover_media_id 全程逐字不變';

  -- owner（非作者）：軟刪別人的——這是 §10 授權的那件事，且只動 deleted_at。
  -- 比對對象是 INSERT 後拍的 v_snapshot（未受前面兩次作者呼叫影響），不是重新在
  -- 這裡才拍的「當下值」——這正是 F1 要修的那個 baseline 時機錯誤。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 用 set_album_deleted 軟刪別人的相簿沒有生效';
  end if;
  if (select to_jsonb(a) - 'deleted_at' - 'deleted_by' from public.albums a where a.id = v_album)
     is distinct from v_snapshot then
    raise exception 'FAIL：owner 軟刪別人的相簿時，deleted_at 以外的欄位被動到了（title/child_id/cover_media_id 有一項跟 INSERT 當下的值不一樣）——set_album_deleted 不該碰得到內容欄位';
  end if;
  raise notice 'ok：owner 可以用 set_album_deleted 軟刪別人的相簿，且整列（除 deleted_at 外）逐欄逐字不變';

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

  -- viewer（非作者）：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：非作者的 viewer 竟然可以用 set_album_deleted 動別人的相簿';
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

  -- 作者已離開家庭：完全不在 family_members 裡了，連軟刪自己過去建立的都不行
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

  -- F5（orchestrator PR #70 review 裁決）：作者被降級成 viewer——仍在
  -- family_members 裡，只是角色變成 viewer——「移除／還原自己的東西」只要求「當下
  -- 仍是成員」，不要求仍是 contributor；「改內容」（§A 的直接 UPDATE）仍要求仍是
  -- contributor，兩者是不同性質的操作，見 migration 對這支函式的裁量說明。
  --
  -- 此時相簿處於已軟刪狀態、deleted_by=v_owner（上一段 owner 軟刪的結果）——LS-57：
  -- 降級成 viewer 的前作者呼叫還原，即使通過了「仍是成員」這關，還是會被還原鎖擋下
  -- （LS027，這本不是他自己刪的）。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_deleted(v_album, false);
    raise exception 'FAIL：被降級成 viewer 的前作者，竟然還原了 owner 軟刪的相簿——LS-57 的還原鎖沒有生效';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is null then
    raise exception 'FAIL：被 LS027 擋下的還原呼叫，deleted_at 竟然還是被清掉了';
  end if;
  raise notice 'ok：被降級成 viewer 的前作者無法用 set_album_deleted 還原 owner 軟刪的相簿（LS027）——LS-57';

  -- owner 可以還原任何一本，不限於自己刪的。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, false);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is not null then
    raise exception 'FAIL：owner 還原別人相簿（自己不是原建立者）卻沒有生效';
  end if;
  raise notice 'ok：owner 可以還原家庭內任何一本相簿，不限於自己軟刪的——LS-57';

  -- 降級成 viewer 的作者仍可軟刪／還原「自己」設下的 deleted_at——降級本身不影響
  -- 對自己內容的處置權，這是 F5 既有結論，LS-57 沒有改變這件事，只是新增了「別人
  -- （owner）設下的不能自行還原」這一層。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_deleted(v_album, true);
  perform public.set_album_deleted(v_album, false);
  reset role;
  select deleted_at into v_deleted_at from public.albums where id = v_album;
  if v_deleted_at is not null then
    raise exception 'FAIL：被降級成 viewer 的作者，軟刪／還原自己設下的 deleted_at 卻沒有生效';
  end if;
  if (select to_jsonb(a) - 'deleted_at' - 'deleted_by' from public.albums a where a.id = v_album)
     is distinct from v_snapshot then
    raise exception 'FAIL：被降級成 viewer 的作者軟刪／還原自己相簿時，deleted_at 以外的欄位被動到了';
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的作者仍可用 set_album_deleted 軟刪／還原「自己」設下的 deleted_at（只要求仍是成員，不要求仍是 contributor）——F5 回歸，LS-57 未改變這件事';

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
-- LS-58 更新：comments 的寫入面已從本段原本測的「hybrid 模式」（作者直接 UPDATE
-- 放行、owner 分支才收斂）進一步收斂成 RPC-only（見
-- 20260825020000_comments_reactions_notifications.sql 第 0 段）——comments_update
-- policy 已被 ALTER 成 `using (false) with check (false)`，UPDATE grant 也整個
-- revoke。這代表本段原本驗的「作者直接 UPDATE 放行、owner 分支 0 列」已經不成立：
-- 現在不分是誰，直接 UPDATE 一律 42501（連作者自己也一樣）。完整的角色矩陣（作者／
-- owner／member／viewer／外人／已離開／降級）改測 update_comment RPC，見
-- supabase/tests/87_comments_reactions_notifications.sql §B——這裡只留一條回歸，
-- 證明「直接 UPDATE 現在連作者本人都會被擋下」沒有被之後的改動悄悄鬆開。
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_target_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_comment uuid;
begin
  set local role postgres;
  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (v_family, 'media', v_target_media, v_author, '原始留言')
  returning id into v_comment;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.comments set body = '作者想直接改' where id = v_comment;
    raise exception 'FAIL：LS-58 之後直接 UPDATE comments 應該對任何人（含作者本人）都是 42501，作者本人竟然成功了';
  exception when insufficient_privilege then
    raise notice 'ok（LS-58 回歸）：作者本人直接 UPDATE 自己的留言 body 現在也是 42501（RPC-only，見 update_comment）';
  end;
  reset role;
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
  v_snapshot jsonb;
  v_deleted_at timestamptz;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls52.test', now(), now(), '{}', '{}');
  -- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員')
    on conflict (id) do update set display_name = excluded.display_name;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);

  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (v_family, 'media', v_target_media, v_author, '會被軟刪又還原的留言')
  returning id into v_comment;

  -- F1（merge-reviewer PR #70 review，同 §B 的說明）：baseline 必須在任何 RPC
  -- 呼叫之前擷取，且改成整列比對（`to_jsonb(row) - 'deleted_at'`）而不是只列舉
  -- body 一欄。
  select to_jsonb(c) - 'deleted_at' - 'deleted_by' into v_snapshot from public.comments c where c.id = v_comment;
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
  if (select to_jsonb(c) - 'deleted_at' - 'deleted_by' from public.comments c where c.id = v_comment)
     is distinct from v_snapshot then
    raise exception 'FAIL：作者軟刪自己的留言時，deleted_at 以外的欄位被動到了';
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
  if (select to_jsonb(c) - 'deleted_at' - 'deleted_by' from public.comments c where c.id = v_comment)
     is distinct from v_snapshot then
    raise exception 'FAIL：作者還原自己的留言時，deleted_at 以外的欄位被動到了';
  end if;
  raise notice 'ok：作者本人可以用 set_comment_deleted 軟刪／還原自己的留言，且 body 全程逐字不變';

  -- owner（非作者）：軟刪別人的，只動 deleted_at。比對對象是 INSERT 後拍的
  -- v_snapshot（未受前面兩次作者呼叫影響），不是重新在這裡才拍的「當下值」。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 用 set_comment_deleted 軟刪別人的留言沒有生效';
  end if;
  if (select to_jsonb(c) - 'deleted_at' - 'deleted_by' from public.comments c where c.id = v_comment)
     is distinct from v_snapshot then
    raise exception 'FAIL：owner 軟刪別人的留言時，deleted_at 以外的欄位被動到了（body 跟 INSERT 當下的值不一樣）——set_comment_deleted 不該碰得到內容欄位';
  end if;
  raise notice 'ok：owner 可以用 set_comment_deleted 軟刪別人的留言，且整列（除 deleted_at 外）逐欄逐字不變';

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

  -- 作者被降級成 viewer：仍在 family_members 裡（跟直接 UPDATE 的判準一致，
  -- comments 的作者分支只要求仍是任一角色的成員）。此時留言處於已軟刪狀態、
  -- deleted_by=v_owner（上一段 owner 軟刪的結果）——LS-57：降級成 viewer 的前作者
  -- 呼叫還原，即使通過了「仍是成員」這關，還是會被還原鎖擋下（LS027，這則不是他
  -- 自己刪的）。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_comment_deleted(v_comment, false);
    raise exception 'FAIL：被降級成 viewer 的前作者，竟然還原了 owner 軟刪的留言——LS-57 的還原鎖沒有生效';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is null then
    raise exception 'FAIL：被 LS027 擋下的還原呼叫，deleted_at 竟然還是被清掉了';
  end if;
  raise notice 'ok：被降級成 viewer 的前作者無法用 set_comment_deleted 還原 owner 軟刪的留言（LS027）——LS-57';

  -- owner 可以還原任何一則，不限於自己刪的。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, false);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is not null then
    raise exception 'FAIL：owner 還原別人留言（自己不是原作者）卻沒有生效';
  end if;
  raise notice 'ok：owner 可以還原家庭內任何一則留言，不限於自己軟刪的——LS-57';

  -- 降級成 viewer 的作者仍可軟刪／還原「自己」設下的 deleted_at——降級本身不影響
  -- 對自己內容的處置權，LS-57 沒有改變這件事，只是新增了「別人（owner）設下的
  -- 不能自行還原」這一層。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  perform public.set_comment_deleted(v_comment, false);
  reset role;
  select deleted_at into v_deleted_at from public.comments where id = v_comment;
  if v_deleted_at is not null then
    raise exception 'FAIL：被降級成 viewer 的作者，軟刪／還原自己設下的 deleted_at 卻沒有生效';
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的作者仍可用 set_comment_deleted 軟刪／還原「自己」設下的 deleted_at（作者分支只要求仍是任一角色的成員，跟直接 UPDATE 一致）——LS-57 未改變這件事';

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
-- albums 在 LS-52 當時**沒有**動表級 grant（跟 LS-48 對 diaries 整個 revoke
-- 不同——那時作者仍走直接 UPDATE，grant 留著整表）；**LS-57 R2 起這個現況已經
-- 改變**：deleted_at／deleted_by／family_id 三欄的欄位級 grant 被收回，只保留
-- title／child_id／cover_media_id 三欄（N1/N2 根治，見
-- 20260825040000_deletion_attribution.sql 檔頭），`has_table_privilege(...,
-- 'update')`（檢查的是整表 relacl，不含欄位級 attacl）因此從 R1 之前的 `true`
-- 變成 `false`——下面的斷言已同步改寫成驗這個新現況，不是複製 R1 之前的舊斷言；
-- 88_deletion_attribution.sql／60_default_privileges.sql 有更細的欄位級
-- has_column_privilege 斷言，這裡驗的是表級／整體現況的回歸對照。
--
-- comments 則不同：LS-58（20260825020000_comments_reactions_notifications.sql）
-- 把 comments 的寫入面從這裡原本測的 hybrid 模式進一步收斂成 RPC-only，INSERT／
-- UPDATE 的表級 grant 已被整個 revoke（比照 diaries），只剩 SELECT／DELETE 兩個
-- grant 還在——下面改成驗這個新現況，不是複製 albums 那份斷言。
--
-- 另外驗 albums／comments 各自新增 RPC 的 EXECUTE 授權（authenticated 可、anon
-- 不可），這些也要納入 supabase/tests/60_default_privileges.sql §8 的 public RPC
-- 白名單，否則會被那邊「清單外函式」那段擋下——本檔與 LS-58 都已同步更新那個
-- 白名單，這裡不重複驗 definer／search_path 硬化（60_ 已經涵蓋）。
-- ---------------------------------------------------------------------------
do $$
begin
  -- LS-57 R2：albums 的表級 UPDATE grant 已被收回（只留欄位級子集合），
  -- has_table_privilege 對整表 UPDATE 應該回 false——這是正向回歸，不是漏洞。
  if has_table_privilege('authenticated', 'public.albums', 'update') then
    raise exception 'FAIL 回歸：authenticated 竟然還有 albums 的表級 UPDATE grant——LS-57 R2 應該已收回整表 UPDATE、只留欄位級子集合（title/child_id/cover_media_id）';
  end if;
  if not has_column_privilege('authenticated', 'public.albums', 'title', 'update') then
    raise exception 'FAIL 回歸：authenticated 失去 albums.title 的欄位級 UPDATE——作者直接編輯內容的路徑會跟著壞掉';
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
  raise notice 'ok 回歸：albums 的 SELECT/INSERT/DELETE 表級 grant 原封不動，UPDATE 已收斂成欄位級子集合（LS-57 R2）——縮權靠 policy 窄化＋欄位級 grant 兩層，不再只靠 policy';

  -- LS-58：comments 的 INSERT／UPDATE grant 已被整個 revoke（RPC-only，同 diaries）。
  if has_table_privilege('authenticated', 'public.comments', 'insert') then
    raise exception 'FAIL 回歸（LS-58）：authenticated 竟然還有 comments 的表級 INSERT grant——應該已收斂成 RPC-only（create_comment）';
  end if;
  if has_table_privilege('authenticated', 'public.comments', 'update') then
    raise exception 'FAIL 回歸（LS-58）：authenticated 竟然還有 comments 的表級 UPDATE grant——應該已收斂成 RPC-only（update_comment／set_comment_deleted）';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 DELETE grant（owner 硬刪的路徑）';
  end if;
  raise notice 'ok 回歸（LS-58）：comments 的 INSERT/UPDATE 表級 grant 已收回（RPC-only），SELECT/DELETE 原樣保留';

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
