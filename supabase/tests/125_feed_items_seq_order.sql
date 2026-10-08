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
-- Mutation 自證見 LS-415 handoff。

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

  reset role;
  raise notice 'ok：LS-415 全部通過（含 ref_id 與建立順序相反的同日三筆）';
end;
$$;

rollback;
