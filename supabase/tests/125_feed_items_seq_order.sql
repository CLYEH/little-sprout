-- LS-415 — 時間軸同日排序穩定鍵 `seq`（20260930051701_feed_items_seq.sql）。
--
-- 問題：diary（entry_date）與 food_first（first_tried_on）的 occurred_at 都是 UTC 午夜，同一天
-- 的卡片 occurred_at 完全相同，舊 keyset 第二鍵 ref_id 是隨機 uuid → 同日順序與建立順序無關。
--
-- 這支測試刻意把「建立順序」與「ref_id 順序」擺成**相反**（ref_id 明確指定）：
--   建立順序：d1（ffff…）→ f1（8000…）→ d2（0000…）；期望時間軸（新→舊）：d2、f1、d1
--   ref_id desc：d1、f1、d2——若排序鍵退回 ref_id（或 seq 從 order by 拿掉），回傳順序剛好反過來。
-- 三筆都放在 2100-06-15（比任何 fixture 都新），所以在家族時間軸恆為前三列。
--
-- 角色：A 家（fa…001）member=a2 身分走 RPC（security invoker，RLS 生效）；資料準備以 postgres 直寫。
-- Mutation 自證見 LS-415 handoff；§7（albums／media 沿用舊 seq）、§8（封鎖＋游標＋同日）見 LS-419 handoff。

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_child  uuid := '2a000000-0000-4000-8000-000000000001';
  v_d1 uuid := 'ffffffff-0000-4000-8000-000000000415';
  v_f1 uuid := '80000000-0000-4000-8000-000000000415';
  v_d2 uuid := '00000000-0000-4000-8000-000000000415';
  v_day date := date '2100-06-15';
  v_food text;
  v_got uuid[];
  v_want uuid[];
  v_all uuid[];
  v_walk uuid[];
  v_page record;
  v_cur_at timestamptz;
  v_cur_ref uuid;
  v_rows record;
  v_n int;
begin
  -- ---- 資料準備（postgres）：依 d1 → f1 → d2 的順序建立 ---------------------
  select id into v_food from public.food_catalog order by sort_order limit 1;

  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_d1, v_family, v_member, 'LS-415 d1（最早建立）', v_day);
  insert into public.child_food_records (id, family_id, child_id, food_id, author_id, first_tried_on)
  values (v_f1, v_family, v_child, v_food, v_member, v_day);
  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_d2, v_family, v_member, 'LS-415 d2（最晚建立）', v_day);

  -- 兩篇日記標給小芽：per-child 視角要看得到 d1、d2、f1
  insert into public.diary_children (family_id, diary_id, child_id) values
    (v_family, v_d1, v_child), (v_family, v_d2, v_child);

  v_want := array[v_d2, v_f1, v_d1];   -- 新 → 舊（建立順序倒序）

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ---- 1. 家族時間軸：同日三筆（diary／food_first／diary）依建立順序倒序 -----
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, null, null, null, 3)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is distinct from v_want then
    raise exception 'FAIL：家族時間軸同日三筆應依建立順序倒序 [d2, f1, d1]，實際 %（預期 %）——第二排序鍵不是建立順序', v_got, v_want;
  end if;
  raise notice 'ok：家族時間軸同日 diary／food_first／diary 依建立順序倒序（d2, f1, d1），與 ref_id 順序相反';

  -- ---- 2. limit 2 跨同日邊界分兩頁：不重複、不漏 -----------------------------
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, null, null, null, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is distinct from array[v_d2, v_f1] then
    raise exception 'FAIL：第 1 頁（limit 2）應為 [d2, f1]，實際 %', v_got;
  end if;

  select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref   -- 第 1 頁最後一列（f1）
    from public.get_family_timeline(v_family, null, null, null, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
   order by t.n desc limit 1;
  if v_cur_ref is distinct from v_f1 then
    raise exception 'SETUP FAIL：第 1 頁最後一列應為 f1，取到 %', v_cur_ref;
  end if;

  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got[1] is distinct from v_d1 then
    raise exception 'FAIL：第 2 頁（游標＝f1）第一列應為同日剩下的 d1，實際 %（同日邊界漏列或重複）', v_got;
  end if;
  if v_d2 = any(v_got) or v_f1 = any(v_got) then
    raise exception 'FAIL：第 2 頁不應重複第 1 頁已出現的列，實際 %', v_got;
  end if;
  raise notice 'ok：limit 2 跨同日邊界——第 1 頁 [d2, f1]、第 2 頁以 f1 為游標從 d1 接續，不重複不漏';

  -- 整條走完：逐頁串接（limit 2）必須等於一次取完（limit 100）
  select array_agg(t.ref_id order by t.n) into v_all
    from public.get_family_timeline(v_family, null, null, null, 100)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  v_walk := '{}';
  v_cur_at := null; v_cur_ref := null;
  loop
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 2)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    exit when v_got is null;
    v_walk := v_walk || v_got;
    select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref
      from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 2)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
     order by t.n desc limit 1;
    exit when array_length(v_walk, 1) > 1000;   -- 防無窮迴圈
  end loop;
  if v_walk is distinct from v_all then
    raise exception 'FAIL：逐頁（limit 2）串接與一次取完不一致（% 列 vs % 列）——分頁重複或遺漏', array_length(v_walk, 1), array_length(v_all, 1);
  end if;
  raise notice 'ok：家族時間軸 limit 2 逐頁走完（% 列）＝一次取完', array_length(v_all, 1);

  -- ---- 3. per-child 版同案 ------------------------------------------------
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, v_child, null, null, 3)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is distinct from v_want then
    raise exception 'FAIL：per-child 時間軸同日三筆應依建立順序倒序 [d2, f1, d1]，實際 %', v_got;
  end if;

  select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref
    from public.get_family_timeline(v_family, v_child, null, null, 2) with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
   order by t.n desc limit 1;
  if v_cur_ref is distinct from v_f1 then
    raise exception 'SETUP FAIL：per-child 第 1 頁最後一列應為 f1，取到 %', v_cur_ref;
  end if;
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, v_child, v_cur_at, v_cur_ref, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got[1] is distinct from v_d1 or v_d2 = any(v_got) or v_f1 = any(v_got) then
    raise exception 'FAIL：per-child 第 2 頁（游標＝f1）應從 d1 接續且不重複，實際 %', v_got;
  end if;

  select array_agg(t.ref_id order by t.n) into v_all
    from public.get_family_timeline(v_family, v_child, null, null, 100)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  v_walk := '{}';
  v_cur_at := null; v_cur_ref := null;
  loop
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, v_child, v_cur_at, v_cur_ref, 2)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    exit when v_got is null;
    v_walk := v_walk || v_got;
    select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref
      from public.get_family_timeline(v_family, v_child, v_cur_at, v_cur_ref, 2)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
     order by t.n desc limit 1;
    exit when array_length(v_walk, 1) > 1000;
  end loop;
  if v_walk is distinct from v_all then
    raise exception 'FAIL：per-child 逐頁（limit 2）串接與一次取完不一致（% 列 vs % 列）', array_length(v_walk, 1), array_length(v_all, 1);
  end if;
  raise notice 'ok：per-child 版——同日倒序、跨邊界分頁、逐頁走完（% 列）＝一次取完', array_length(v_all, 1);

  -- ---- 4. 編輯不改變建立順序（UPDATE 的 delete＋reinsert 沿用舊 seq）----------
  reset role;
  update public.diaries set body = 'LS-415 d1 已編輯' where id = v_d1;
  update public.child_food_records set note = 'LS-415 f1 已編輯' where id = v_f1;
  -- 重新標記（刪多補少的路徑）：d1 換標記後 feed_item_children.seq 仍等於 feed_items.seq
  delete from public.diary_children where diary_id = v_d1;
  insert into public.diary_children (family_id, diary_id, child_id) values (v_family, v_d1, v_child);
  select count(*) into v_n
    from public.feed_item_children c
    join public.feed_items f on f.kind = c.kind and f.ref_id = c.ref_id
   where c.ref_id in (v_d1, v_f1, v_d2) and c.seq is distinct from f.seq;
  if v_n <> 0 then
    raise exception 'FAIL：% 列 feed_item_children.seq 與對應 feed_items.seq 不一致（家族／per-child 同日順序會分歧）', v_n;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, null, null, null, 3)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is distinct from v_want then
    raise exception 'FAIL：編輯 d1／f1 後家族順序變成 %（預期仍為 [d2, f1, d1]）——UPDATE 的 delete＋reinsert 沒沿用舊 seq，編輯過的卡片跳到同日最新', v_got;
  end if;
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, v_child, null, null, 3)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is distinct from v_want then
    raise exception 'FAIL：編輯／重新標記後 per-child 順序變成 %（預期仍為 [d2, f1, d1]）', v_got;
  end if;
  raise notice 'ok：編輯內文／備註、重新標記孩子之後同日順序不變，feed_item_children.seq 與 feed_items.seq 一致';

  -- ---- 5. 游標指向已刪列：退回 (occurred_at, ref_id) 比較，不報錯 -----------------
  -- 先取 f1 當游標，再把 f1 軟刪（feed_items 列消失）——模擬「兩頁之間游標列被刪」。
  select t.occurred_at into v_cur_at
    from public.get_family_timeline(v_family, null, null, null, 3) t where t.ref_id = v_f1;
  v_cur_ref := v_f1;
  reset role;
  update public.child_food_records set deleted_at = now(), deleted_by = v_member where id = v_f1;
  if exists (select 1 from public.feed_items where kind = 'food_first' and ref_id = v_f1) then
    raise exception 'SETUP FAIL：軟刪 f1 後 feed_items 列應消失';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 家族版
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is null or v_got[1] is distinct from v_d2 then
    raise exception 'FAIL：游標列已刪時應退回 (occurred_at, ref_id) 比較——ref_id 小於游標的 d2（0000…）應是第一列，實際 %', v_got;
  end if;
  if v_d1 = any(v_got) then
    raise exception 'FAIL：游標列已刪的退回比較不應回傳 ref_id 大於游標的 d1（ffff…），實際 %', v_got;
  end if;
  -- per-child 版
  select array_agg(t.ref_id order by t.n) into v_got
    from public.get_family_timeline(v_family, v_child, v_cur_at, v_cur_ref, 2)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_got is null or v_got[1] is distinct from v_d2 or v_d1 = any(v_got) then
    raise exception 'FAIL：per-child 游標列已刪時退回比較結果不對，實際 %（預期第一列 d2 且不含 d1）', v_got;
  end if;
  raise notice 'ok：游標指向已刪列 → 退回 (occurred_at, ref_id) 比較，家族／per-child 皆不報錯、照常翻頁';

  -- ---- 6. 游標反查的 ±1ms 視窗（merge-review R1 m1）------------------------------
  -- iOS 以毫秒精度序列化游標時間，album／media 的 occurred_at 是微秒精度。同一微秒批次建
  -- 3 本相簿（2100-07-01，比 1–5 段的資料都新 → 家族時間軸恆為前三列），游標時間截到毫秒
  -- 後以 limit 1 逐頁翻：反查若改成等值比對會查不到游標列、退回 (截斷時間, ref_id) 比較，
  -- 而截斷時間比三本的真實時間都早 → 同批另外 2 本被整批跳過。
  reset role;
  insert into public.albums (id, family_id, title, created_by, created_at) values
    ('a1500000-0000-4000-8000-000000000001', v_family, 'LS-415 同微秒相簿 1', v_member, timestamptz '2100-07-01 10:00:00.123456+00'),
    ('a1500000-0000-4000-8000-000000000002', v_family, 'LS-415 同微秒相簿 2', v_member, timestamptz '2100-07-01 10:00:00.123456+00'),
    ('a1500000-0000-4000-8000-000000000003', v_family, 'LS-415 同微秒相簿 3', v_member, timestamptz '2100-07-01 10:00:00.123456+00');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select array_agg(t.ref_id order by t.n) into v_all
    from public.get_family_timeline(v_family, null, null, null, 100)
         with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
  if v_all[1:3] is distinct from array[
       'a1500000-0000-4000-8000-000000000003', 'a1500000-0000-4000-8000-000000000002',
       'a1500000-0000-4000-8000-000000000001']::uuid[] then
    raise exception 'SETUP FAIL：同微秒三本相簿應為家族時間軸前三列（建立順序倒序），實際 %', v_all[1:3];
  end if;
  v_walk := '{}';
  v_cur_at := null; v_cur_ref := null;
  loop
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 1)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    exit when v_got is null;
    v_walk := v_walk || v_got;
    select date_trunc('milliseconds', t.occurred_at), t.ref_id into v_cur_at, v_cur_ref
      from public.get_family_timeline(v_family, null, v_cur_at, v_cur_ref, 1) t;
    exit when array_length(v_walk, 1) > 1000;
  end loop;
  if v_walk is distinct from v_all then
    raise exception 'FAIL：毫秒截斷游標逐頁（limit 1）串接與一次取完不一致（% 列 vs % 列，前三列 % vs %）——游標反查少了 ±1ms 視窗，同微秒批次被跳過',
      array_length(v_walk, 1), array_length(v_all, 1), v_walk[1:3], v_all[1:3];
  end if;
  raise notice 'ok：同微秒批次三本相簿，毫秒截斷游標 limit 1 逐頁走完（% 列）＝一次取完', array_length(v_all, 1);

  -- ---- 7. albums／media 的 UPDATE 也沿用舊 seq（LS-419；池 `1de820f8`）----------------
  -- §4 只編輯 diaries／child_food_records。feed_sync_albums／feed_sync_media 同樣對任何 UPDATE
  -- 先刪後寫 feed_items；reinsert 若改回 nextval（不沿用舊 seq），被編輯的那本相簿／那張照片
  -- 會跳到同一瞬間的最新。作法同 §1：同一個 occurred_at 各建兩筆、建立順序與 ref_id 順序相反，
  -- 編輯「先建立」的那筆，斷言它的 seq 不變、家族時間軸順序不變。
  -- 時間 2100-07-20（比 §1–§6 都新）→ 家族時間軸前四列恆為這四筆（相簿 09:00、照片 08:00）。
  -- media 沒有 caption 欄，改 width／height（authenticated 有 UPDATE grant 的欄位；校正轉向的情境）。
  declare
    v_ax uuid := 'ffffffff-0000-4000-8000-000000004191';   -- 相簿 X：先建立
    v_ay uuid := '00000000-0000-4000-8000-000000004191';   -- 相簿 Y：後建立
    v_mx uuid := 'ffffffff-0000-4000-8000-000000004192';   -- 照片 X：先建立
    v_my uuid := '00000000-0000-4000-8000-000000004192';   -- 照片 Y：後建立
    v_order uuid[];
    v_seq_before bigint;
    v_seq_after bigint;
  begin
    reset role;
    insert into public.albums (id, family_id, title, created_by, created_at)
    values (v_ax, v_family, 'LS-419 相簿 X（先建立）', v_member, timestamptz '2100-07-20 09:00:00.250000+00');
    insert into public.albums (id, family_id, title, created_by, created_at)
    values (v_ay, v_family, 'LS-419 相簿 Y（後建立）', v_member, timestamptz '2100-07-20 09:00:00.250000+00');
    -- taken_at 有「不得晚於 now()+1 天」的 CHECK，所以留 NULL、occurred_at 取 created_at
    insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
    values (v_mx, v_family, v_family::text || '/2100/07/' || v_mx::text || '.jpg', 'photo', 1024, null, 3024, 4032,
            v_member, timestamptz '2100-07-20 08:00:00.250000+00');
    insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
    values (v_my, v_family, v_family::text || '/2100/07/' || v_my::text || '.jpg', 'photo', 1024, null, 3024, 4032,
            v_member, timestamptz '2100-07-20 08:00:00.250000+00');

    v_order := array[v_ay, v_ax, v_my, v_mx];   -- 新 → 舊（同一瞬間依建立順序倒序；ref_id desc 會剛好相反）

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, null, null, null, 4)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    if v_got is distinct from v_order then
      raise exception 'SETUP FAIL：§7 家族時間軸前四列應為 [相簿 Y, 相簿 X, 照片 Y, 照片 X]，實際 %（預期 %）', v_got, v_order;
    end if;

    -- 相簿：改標題
    reset role;
    select f.seq into v_seq_before from public.feed_items f where f.kind = 'album' and f.ref_id = v_ax;
    update public.albums set title = 'LS-419 相簿 X 已改標題' where id = v_ax;
    select f.seq into v_seq_after from public.feed_items f where f.kind = 'album' and f.ref_id = v_ax;
    if v_seq_after is distinct from v_seq_before then
      raise exception 'FAIL：相簿 X 改標題後 feed_items.seq 由 % 變成 %——feed_sync_albums 的 UPDATE（delete＋reinsert）沒沿用舊 seq', v_seq_before, v_seq_after;
    end if;

    -- 照片：改 width／height
    select f.seq into v_seq_before from public.feed_items f where f.kind = 'media' and f.ref_id = v_mx;
    update public.media set width = 4032, height = 3024 where id = v_mx;
    select f.seq into v_seq_after from public.feed_items f where f.kind = 'media' and f.ref_id = v_mx;
    if v_seq_after is distinct from v_seq_before then
      raise exception 'FAIL：照片 X 改 width／height 後 feed_items.seq 由 % 變成 %——feed_sync_media 的 UPDATE（delete＋reinsert）沒沿用舊 seq', v_seq_before, v_seq_after;
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, null, null, null, 4)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    if v_got is distinct from v_order then
      raise exception 'FAIL：編輯相簿 X／照片 X 後家族時間軸前四列變成 %（預期仍為 %）——被編輯的卡片跳到同一瞬間的最新', v_got, v_order;
    end if;
  end;
  raise notice 'ok：相簿改標題、照片改 width／height 後 seq 不變，同一瞬間的順序不變（feed_sync_albums／feed_sync_media 沿用舊 seq）';

  -- ---- 8. 封鎖＋游標＋同日（LS-419；池 `c5c1dc87`）------------------------------------
  -- get_family_timeline 的 v_has_blocks=true 有四條獨立分支（家族／per-child × 有無游標），
  -- 文字與無封鎖版相同，但 §1–§6 都沒有封鎖，走不到。這裡讓 member（a2）封鎖 owner（a1），
  -- 同日（2100-08-01，比 §1–§7 都新）依序建立 m1、b1、m2、b2、m3、b3（m＝a2 寫、b＝a1 寫；
  -- 有 diary 也有 food_first；看得見的三筆 ref_id 順序與建立順序相反）。封鎖後：
  --   - 單次查詢不含 b*，前三列＝[m3, m2, m1]；
  --   - limit 2 第 1 頁 [m3, m2]，以 m2 為游標的第 2 頁從 m1 接續（同日群組切在頁界中間，
  --     中間夾著被濾掉的 b1／b2），逐頁走完＝單次查詢、全程不含 b*；
  --   - per-child 同案（四篇日記都標小芽，food_first 本身就是小芽的）。
  declare
    v_owner uuid := 'a0000000-0000-4000-8000-000000000001';   -- 被封鎖者
    v_m1 uuid := 'ffffffff-0000-4000-8000-000000004193';
    v_b1 uuid := 'c0000000-0000-4000-8000-000000004193';
    v_m2 uuid := '80000000-0000-4000-8000-000000004193';
    v_b2 uuid := '40000000-0000-4000-8000-000000004193';
    v_m3 uuid := '00000000-0000-4000-8000-000000004193';
    v_b3 uuid := '20000000-0000-4000-8000-000000004193';
    v_bday date := date '2100-08-01';
    v_food_m text;
    v_food_b text;
    v_blocked uuid[];
    v_scope uuid;
    v_label text;
  begin
    reset role;
    -- 兩種小芽目前沒有未刪除記錄的食物（child_food_records 對 (child_id, food_id) 有部分唯一索引）
    select c.id into v_food_m from public.food_catalog c
     where not exists (select 1 from public.child_food_records r
                        where r.child_id = v_child and r.food_id = c.id and r.deleted_at is null)
     order by c.sort_order limit 1;
    select c.id into v_food_b from public.food_catalog c
     where c.id <> v_food_m
       and not exists (select 1 from public.child_food_records r
                        where r.child_id = v_child and r.food_id = c.id and r.deleted_at is null)
     order by c.sort_order limit 1;

    insert into public.diaries (id, family_id, author_id, body, entry_date)
    values (v_m1, v_family, v_member, 'LS-419 m1', v_bday);
    insert into public.diaries (id, family_id, author_id, body, entry_date)
    values (v_b1, v_family, v_owner, 'LS-419 b1（被封鎖者）', v_bday);
    insert into public.child_food_records (id, family_id, child_id, food_id, author_id, first_tried_on)
    values (v_m2, v_family, v_child, v_food_m, v_member, v_bday);
    insert into public.child_food_records (id, family_id, child_id, food_id, author_id, first_tried_on)
    values (v_b2, v_family, v_child, v_food_b, v_owner, v_bday);
    insert into public.diaries (id, family_id, author_id, body, entry_date)
    values (v_m3, v_family, v_member, 'LS-419 m3', v_bday);
    insert into public.diaries (id, family_id, author_id, body, entry_date)
    values (v_b3, v_family, v_owner, 'LS-419 b3（被封鎖者）', v_bday);
    insert into public.diary_children (family_id, diary_id, child_id) values
      (v_family, v_m1, v_child), (v_family, v_b1, v_child),
      (v_family, v_m3, v_child), (v_family, v_b3, v_child);

    v_blocked := array[v_b1, v_b2, v_b3];

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- SETUP：封鎖前六筆都看得到、依建立順序倒序——證明下面消失的 b* 是封鎖造成的
    select array_agg(t.ref_id order by t.n) into v_got
      from public.get_family_timeline(v_family, null, null, null, 6)
           with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
    if v_got is distinct from array[v_b3, v_m3, v_b2, v_m2, v_b1, v_m1] then
      raise exception 'SETUP FAIL：§8 封鎖前家族時間軸前六列應為 [b3, m3, b2, m2, b1, m1]，實際 %', v_got;
    end if;

    perform public.block_user(v_family, v_owner);

    -- 家族（p_child_id null）與 per-child 各跑一次同一組斷言
    foreach v_scope in array array[null, v_child]::uuid[] loop
      v_label := case when v_scope is null then '家族' else 'per-child' end;

      select array_agg(t.ref_id order by t.n) into v_all
        from public.get_family_timeline(v_family, v_scope, null, null, 100)
             with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
      if v_all && v_blocked then
        raise exception 'FAIL：%時間軸封鎖後單次查詢仍含被封鎖者的卡片，實際前六列 %', v_label, v_all[1:6];
      end if;
      if v_all[1:3] is distinct from array[v_m3, v_m2, v_m1] then
        raise exception 'FAIL：%時間軸封鎖後同日三筆應依建立順序倒序 [m3, m2, m1]，實際 %', v_label, v_all[1:3];
      end if;

      -- 第 1 頁（封鎖＋無游標分支）
      select array_agg(t.ref_id order by t.n) into v_got
        from public.get_family_timeline(v_family, v_scope, null, null, 2)
             with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
      if v_got is distinct from array[v_m3, v_m2] then
        raise exception 'FAIL：%時間軸封鎖後第 1 頁（limit 2）應為 [m3, m2]，實際 %', v_label, v_got;
      end if;
      select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref
        from public.get_family_timeline(v_family, v_scope, null, null, 2)
             with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
       order by t.n desc limit 1;
      -- 第 2 頁（封鎖＋游標分支）：游標＝m2，同日群組切在頁界中間
      select array_agg(t.ref_id order by t.n) into v_got
        from public.get_family_timeline(v_family, v_scope, v_cur_at, v_cur_ref, 2)
             with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
      if v_got[1] is distinct from v_m1 or v_m3 = any(v_got) or v_m2 = any(v_got) or v_got && v_blocked then
        raise exception 'FAIL：%時間軸封鎖後第 2 頁（游標＝m2）應從 m1 接續、不重複、不含被封鎖者，實際 %', v_label, v_got;
      end if;

      -- 逐頁走完（每頁都走封鎖＋游標分支）＝單次查詢
      v_walk := '{}';
      v_cur_at := null; v_cur_ref := null;
      loop
        select array_agg(t.ref_id order by t.n) into v_got
          from public.get_family_timeline(v_family, v_scope, v_cur_at, v_cur_ref, 2)
               with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n);
        exit when v_got is null;
        v_walk := v_walk || v_got;
        select t.occurred_at, t.ref_id into v_cur_at, v_cur_ref
          from public.get_family_timeline(v_family, v_scope, v_cur_at, v_cur_ref, 2)
               with ordinality as t(kind, ref_id, occurred_at, taken_at, child_ids, comment_count, n)
         order by t.n desc limit 1;
        exit when array_length(v_walk, 1) > 1000;
      end loop;
      if v_walk is distinct from v_all then
        raise exception 'FAIL：%時間軸封鎖後逐頁（limit 2）串接與一次取完不一致（% 列 vs % 列）——封鎖分支的游標條件重複或遺漏',
          v_label, array_length(v_walk, 1), array_length(v_all, 1);
      end if;
      if v_walk && v_blocked then
        raise exception 'FAIL：%時間軸封鎖後逐頁走訪仍出現被封鎖者的卡片', v_label;
      end if;
      raise notice 'ok：%時間軸封鎖＋游標＋同日——同日倒序 [m3, m2, m1]、跨頁從 m1 接續、逐頁走完（% 列）＝一次取完、不含被封鎖者',
        v_label, array_length(v_all, 1);
    end loop;
  end;

  reset role;
  raise notice 'ok：LS-415 全部通過（含 ref_id 與建立順序相反的同日三筆）';
end;
$$;

rollback;
