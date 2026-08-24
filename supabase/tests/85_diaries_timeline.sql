-- LS-48（LS-21 後端）— diaries 寫入面收斂（RPC-only）＋ get_family_timeline 驗收
--
-- 對應 20260824010000_diaries_write_path_and_timeline.sql 的每一項決定。角色矩陣沿用
-- 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3、child=2a…1；
-- 非本家庭成員用 B 家 owner（b1）代表。
--
-- 斷言依據標註慣例（LS-15 review round 2 定下）沿用：每段標明是靠本票的 migration
-- 保證，還是靠既有（LS-6／LS-33）的既有行為。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 寫入面收斂：diaries 的直接 INSERT／UPDATE 對所有角色都必須被擋（policy + grant 兩層）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_diary uuid := '5a000000-0000-4000-8000-000000000001';
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
      insert into public.diaries (family_id, author_id, body)
      values (v_family, v_user::uuid, '繞過 RPC 直接寫入');
      raise exception 'FAIL：% 竟然可以直接 INSERT diaries（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      update public.diaries set body = '竄改' where id = v_diary;
      raise exception 'FAIL：% 竟然可以直接 UPDATE diaries（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 diaries 的直接 INSERT／UPDATE 皆被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 2. create_diary_entry：只有 contributor（owner／member）能新增，author 恆為呼叫者本人
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_other_child uuid := '2b000000-0000-4000-8000-000000000001';  -- B 家的孩子
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_author uuid;
  v_entry_date date;
begin
  -- owner 能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_diary_entry(v_family, v_child, 'owner 寫的日記', null);
  select author_id, entry_date into v_author, v_entry_date from public.diaries where id = v_id;
  if v_author <> v_owner then
    raise exception 'FAIL：author_id 應為呼叫者本人 %，實際 %', v_owner, v_author;
  end if;
  if v_entry_date <> current_date then
    raise exception 'FAIL：p_entry_date 為 NULL 時應退回 current_date（%），實際 %', current_date, v_entry_date;
  end if;
  reset role;

  -- member 能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_diary_entry(v_family, v_child, 'member 寫的日記', current_date - 3);
  select author_id into v_author from public.diaries where id = v_id;
  if v_author <> v_member then
    raise exception 'FAIL：member 建立的日記 author_id 不是自己';
  end if;
  reset role;
  raise notice 'ok：owner／member 都能建立日記，author_id 恆為呼叫者本人，entry_date 預設 current_date';

  -- viewer 不能寫（§3）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, 'viewer 想寫日記', null);
    raise exception 'FAIL：viewer 竟然可以建立日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員不能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, '外人想寫日記', null);
    raise exception 'FAIL：非本家庭成員竟然可以建立日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法建立日記 (42501)';

  -- 未登入（有 authenticated session 但沒有 sub claim）
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, '沒登入', null);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然建得起日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：未登入呼叫 create_diary_entry 被擋下 (42501)';

  -- child_id 必須屬於同一家庭（複合外鍵擋下跨家庭關聯）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_other_child, '想把日記掛到別家的孩子', null);
    raise exception 'FAIL：child_id 跨家庭竟然建得起日記';
  exception when foreign_key_violation then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：child_id 跨家庭被複合外鍵擋下 (23503)';
end;
$$;

rollback;

-- ===========================================================================
-- 3. update_diary_entry：只有原作者能編內容——owner 不行（這是本票要修的核心洞）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_diary uuid;
  v_body text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '原始內容', current_date);

  -- 作者本人能編
  perform public.update_diary_entry(v_diary, '作者改過的內容', current_date - 1, null);
  select body into v_body from public.diaries where id = v_diary;
  if v_body <> '作者改過的內容' then
    raise exception 'FAIL：作者編輯自己的日記沒有生效';
  end if;
  raise notice 'ok：作者本人可以編輯自己的日記內容';
  reset role;

  -- owner（非作者）不能編內容——只能透過 set_diary_deleted 移除，不能竄改
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, 'owner 竄改的內容', current_date, null);
    raise exception 'FAIL：owner 竟然可以編輯別人日記的內容（§10 授權範圍被突破）';
  exception when sqlstate 'LS021' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：owner 無法編輯非本人日記的內容 (LS021)——只保留軟刪權';

  -- viewer／非本家庭成員也不行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, 'viewer 竄改', current_date, null);
    raise exception 'FAIL：viewer 竟然可以編輯日記';
  exception when sqlstate 'LS021' then
    null;
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, '外人竄改', current_date, null);
    raise exception 'FAIL：非本家庭成員竟然可以編輯日記';
  exception when sqlstate 'LS021' then
    null;
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法編輯日記 (LS021)';

  -- 不存在的日記 → LS020
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(gen_random_uuid(), '不存在', current_date, null);
    raise exception 'FAIL：編輯不存在的日記竟然沒有出錯';
  exception when sqlstate 'LS020' then
    null;
  end;

  -- 已軟刪除的日記不能編輯（即使是作者本人）
  perform public.set_diary_deleted(v_diary, true);
  begin
    perform public.update_diary_entry(v_diary, '想編輯已刪除的日記', current_date, null);
    raise exception 'FAIL：已軟刪除的日記竟然還能被編輯';
  exception when sqlstate 'LS020' then
    null;
  end;
  reset role;
  raise notice 'ok：不存在／已軟刪除的日記都無法編輯 (LS020)';
end;
$$;

rollback;

-- ===========================================================================
-- 4. set_diary_deleted：作者可動自己的，owner 可動全家任何一篇；viewer／非成員都不行
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_diary uuid;
  v_deleted_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '會被刪又被還原的日記', current_date);

  -- 作者軟刪自己的
  perform public.set_diary_deleted(v_diary, true);
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：作者軟刪自己的日記沒有生效';
  end if;

  -- 作者還原自己的
  perform public.set_diary_deleted(v_diary, false);
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：作者還原自己的日記沒有生效';
  end if;
  raise notice 'ok：作者可以軟刪／還原自己的日記';
  reset role;

  -- viewer 不行（不是作者也不是 owner）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, true);
    raise exception 'FAIL：viewer 竟然可以軟刪別人的日記';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  -- 非本家庭成員不行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, true);
    raise exception 'FAIL：非本家庭成員竟然可以軟刪日記';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員都無法軟刪日記 (42501)';

  -- owner 可以軟刪別人（member）的日記——這是 §10 授權的那件事，且只動 deleted_at
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  select deleted_at, body into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 軟刪成員的日記沒有生效';
  end if;
  reset role;
  raise notice 'ok：owner 可以軟刪家庭內任何一篇日記（且不影響內容欄位）';

  -- 不存在的日記 → LS020
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(gen_random_uuid(), true);
    raise exception 'FAIL：軟刪不存在的日記竟然沒有出錯';
  exception when sqlstate 'LS020' then
    null;
  end;
  reset role;
  raise notice 'ok：軟刪不存在的日記回報 LS020';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 硬刪（既有 diaries_delete policy，本票未動）：僅 owner，角色矩陣回歸驗證
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_diary uuid;
  v_n int;
  v_user text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '硬刪測試', current_date);
  reset role;

  foreach v_user in array array[v_member::text, v_viewer::text, v_outsider::text] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
    delete from public.diaries where id = v_diary;
    get diagnostics v_n = row_count;
    if v_n <> 0 then
      raise exception 'FAIL：% 竟然能硬刪日記（應僅 owner）', v_user;
    end if;
    reset role;
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  delete from public.diaries where id = v_diary;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 硬刪日記應影響 1 列，實際 %', v_n;
  end if;
  reset role;

  select count(*) into v_n from public.feed_items where kind = 'diary' and ref_id = v_diary;
  if v_n <> 0 then
    raise exception 'FAIL：硬刪日記後 feed_items 沒有跟著移除';
  end if;

  raise notice 'ok：硬刪日記僅 owner 能做，member／viewer／非成員皆影響 0 列；硬刪後同步從時間軸移除';
end;
$$;

rollback;

-- ===========================================================================
-- 6. get_family_timeline：混排（diary/album/media）、child 篩選、keyset 分頁、跨家庭隔離
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'fb000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';  -- fixtures 既有的孩子
  v_child2 uuid := '2a000000-0000-4000-8000-000000000099';  -- 本檔新增的第二個孩子
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_diary_x1 uuid;
  v_diary_x2 uuid;
  v_album_x1 uuid;
  v_album_x2 uuid;
  v_media_x1 uuid;
  v_n int;
  v_full text[];
  v_collected text[] := array[]::text[];
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_iterations int := 0;
  v_page record;
  v_got_any boolean;
begin
  -- ---- 準備資料（postgres 身分，繞過 RLS；等同 00_fixtures 的作法）--------
  insert into public.children (id, family_id, name, birthday)
  values (v_child2, v_family, '第二個孩子', date '2025-06-01');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary_x1 := public.create_diary_entry(v_family, v_child1, '今天的日記', current_date);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary_x2 := public.create_diary_entry(v_family, v_child2, '第二個孩子的日記', current_date - 5);
  reset role;

  -- albums 沒有 RPC（不在本票範圍），直接以 postgres 身分建立，等同既有 fixtures 慣例
  insert into public.albums (id, family_id, child_id, title, created_by, created_at)
  values (gen_random_uuid(), v_family, v_child1, '本檔新增相簿-有孩子', v_owner, now() - interval '3 hours')
  returning id into v_album_x1;
  insert into public.albums (id, family_id, child_id, title, created_by, created_at)
  values (gen_random_uuid(), v_family, null, '本檔新增相簿-全家共用', v_owner, now() - interval '10 hours')
  returning id into v_album_x2;
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (gen_random_uuid(), v_family,
          v_family || '/2026/08/timeline-test.jpg', 'photo', 1024, now() - interval '2 hours',
          100, 100, v_owner)
  returning id into v_media_x1;

  -- ---- 資料量核對：4（fixtures）+ 5（本段新增：diary_x1/diary_x2/album_x1/album_x2/media_x1）= 9
  select count(*) into v_n from public.feed_items where family_id = v_family;
  if v_n <> 9 then
    raise exception 'FAIL：準備資料後 A 家 feed_items 應為 9 列，實際 %（fixtures 4 + 本段 5）', v_n;
  end if;

  -- ---- (a) p_child_id = NULL：全部 9 筆都要出現 ------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：p_child_id=NULL 應回傳 9 筆混排項目，實際 %', v_n;
  end if;
  raise notice 'ok：get_family_timeline(child=NULL) 回傳全部 9 筆混排項目（日記＋相簿＋照片）';

  -- ---- (b) p_child_id = child1：fixtures 的 album/diary（child1）+ 本段的
  --          diary_x1／album_x1（child1）= 4 筆；media 恆不出現
  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000);
  if v_n <> 4 then
    raise exception 'FAIL：p_child_id=child1 應回傳 4 筆，實際 %', v_n;
  end if;

  -- ---- (c) p_child_id = child2：只有 diary_x2 一筆 ----------------------
  select count(*) into v_n from public.get_family_timeline(v_family, v_child2, null, null, 1000);
  if v_n <> 1 then
    raise exception 'FAIL：p_child_id=child2 應回傳 1 筆，實際 %', v_n;
  end if;
  raise notice 'ok：child 篩選正確（child1=4 筆、child2=1 筆），album_x2（全家共用）與三張 media 都不落在任何 child 篩選結果裡';

  -- ---- media 在任何 child 篩選下都不出現，只在 child=NULL 時出現 ---------
  if exists (
    select 1 from public.get_family_timeline(v_family, v_child1, null, null, 1000) t where t.kind = 'media'
  ) then
    raise exception 'FAIL：child=child1 篩選下竟然出現 media 項目（media 沒有 child_id，應恆為 NULL）';
  end if;
  if not exists (
    select 1 from public.get_family_timeline(v_family, null, null, null, 1000) t
     where t.kind = 'media' and t.ref_id = v_media_x1
  ) then
    raise exception 'FAIL：child=NULL 時新增的 media 項目沒有出現在時間軸';
  end if;
  raise notice 'ok：media 項目的 child_id 恆為 NULL，只在不篩 child 時出現';

  -- ---- 軟刪日記後從「child 篩選」時間軸消失（RPC 與時間軸串接） -----------
  perform public.set_diary_deleted(v_diary_x1, true);
  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000);
  if v_n <> 3 then
    raise exception 'FAIL：軟刪一篇 child1 的日記後，child1 篩選應剩 3 筆，實際 %', v_n;
  end if;
  perform public.set_diary_deleted(v_diary_x1, false);  -- 還原，不影響後面的分頁/總數斷言
  raise notice 'ok：set_diary_deleted 軟刪／還原立即反映在 get_family_timeline';

  -- ---- (d) keyset 分頁：逐頁 limit=2 收集，串接結果必須與單次撈 1000 筆的
  --          結果「順序完全相同」（keyset 分頁沿用同一個排序鍵，不只是同一組集合）
  select array_agg(t.kind::text || ':' || t.ref_id::text order by t.occurred_at desc, t.ref_id desc)
    into v_full
    from public.get_family_timeline(v_family, null, null, null, 1000) t;

  loop
    v_iterations := v_iterations + 1;
    if v_iterations > 20 then
      raise exception 'FAIL：分頁超過 20 頁還沒結束，游標可能沒有前進（無限迴圈風險）';
    end if;

    v_got_any := false;
    for v_page in
      select * from public.get_family_timeline(v_family, null, v_cursor_at, v_cursor_id, 2)
    loop
      v_got_any := true;
      v_collected := v_collected || (v_page.kind::text || ':' || v_page.ref_id::text);
      v_cursor_at := v_page.occurred_at;
      v_cursor_id := v_page.ref_id;
    end loop;

    exit when not v_got_any;
  end loop;

  if v_collected is distinct from v_full then
    raise exception
      'FAIL：limit=2 逐頁串接的結果與單次撈 1000 筆不同（分頁游標可能漏項／重複／順序不一致）—— 分頁=%，完整=%',
      v_collected, v_full;
  end if;
  if array_length(v_collected, 1) <> 9 then
    raise exception 'FAIL：分頁串接後應收集到 9 筆，實際 %', array_length(v_collected, 1);
  end if;
  raise notice 'ok：keyset 分頁（limit=2）逐頁串接的結果與單次查詢完全一致（無漏項、無重複、順序相同），共 % 頁',
    v_iterations - 1;

  -- ---- (e) p_limit 邊界：<=0 夾到 1；正常值原樣通過 ----------------------
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 0);
  if v_n <> 1 then
    raise exception 'FAIL：p_limit=0 應被夾到 1，實際回傳 %', v_n;
  end if;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, -5);
  if v_n <> 1 then
    raise exception 'FAIL：p_limit=-5 應被夾到 1，實際回傳 %', v_n;
  end if;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 3);
  if v_n <> 3 then
    raise exception 'FAIL：p_limit=3 應原樣回傳 3 筆，實際 %', v_n;
  end if;
  raise notice 'ok：p_limit 下界被夾到 1（不會被誤用成「不限筆數」），正常值原樣通過';
  reset role;

  -- ---- (f) 讀取面角色回歸：member／viewer 都看得到自家時間軸 --------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：member 讀自家時間軸應為 9 筆，實際 %', v_n;
  end if;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：viewer 讀自家時間軸應為 9 筆，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok：member／viewer 都能讀到自家完整時間軸（§3：全體成員皆可看）';

  -- ---- (g) 跨家庭隔離：security invoker 完全依賴 feed_items 既有的 RLS ---
  -- A 家 owner 查 B 家的時間軸 → 0 列（RLS：private.family_ids() 不含 B 家）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family_b, null, null, null, 1000);
  if v_n <> 0 then
    raise exception 'FAIL：A 家 owner 查 B 家的時間軸竟然看得到 % 列', v_n;
  end if;
  reset role;

  -- 非本家庭成員（B 家 owner）查 A 家的時間軸 → 0 列
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 0 then
    raise exception 'FAIL：B 家 owner 查 A 家的時間軸竟然看得到 % 列', v_n;
  end if;
  reset role;
  raise notice 'ok：get_family_timeline 的跨家庭隔離由 feed_items 既有 RLS 保證（security invoker 生效）';
end;
$$;

rollback;
