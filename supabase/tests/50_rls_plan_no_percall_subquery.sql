-- LS-6 驗收條件 (c)：RLS policy 不得逐列重算
-- PLAN Phase 0-2 驗證 (c)：「灌幾萬列假資料後 EXPLAIN 證明 policy 沒有 per-row 子查詢
--（隔離對了但會慢的 RLS 等於要重寫）」。
--
-- 判準（兩條都必須成立，缺一不可）：
--   1. plan 裡不能出現 `(SubPlan N)` 形式的 qual 引用 —— 那是 correlated subplan，每列跑一次。
--      hashed SubPlan / InitPlan 的引用會印成 `(hashed SubPlan N)`，不在這個 pattern 內。
--   2. plan 裡所有節點的 loops 都必須是 1 —— 5 萬列的資料量下，只要 policy 被逐列重算，
--      對應節點的 loops 會直接變成上萬。
--
-- 檔尾另外跑一次 EXPLAIN 並把輸出留在 supabase/tests/evidence/ 當證據。
-- 最後一段是偵測器的自我驗證：故意餵一個內嵌 correlated 子查詢的寫法，
-- 判準必須抓得到它——抓不到的話上面三個 ok 全部沒有意義。

\set ON_ERROR_STOP on

begin;

-- 5 萬列假照片（postgres 身分，繞過 RLS）。整個檔案跑在一個交易裡，結束 rollback，不留殘料。
insert into public.media
  (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
select
  'fc000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001/2026/'
    || lpad((1 + (i % 12))::text, 2, '0') || '/perf-' || i || '.jpg',
  'photo', 1024,
  now() - (i * interval '1 minute'),
  3024, 4032,
  'c0000000-0000-4000-8000-000000000001',
  now() - (i * interval '1 minute')
from generate_series(1, 50000) i;

-- LS-33：join_requests 也要有夠多的列，第 4 條查詢的 loops 判準才有意義
-- （空表上「所有節點 loops=1」是恆真句，證明不了 policy 沒有被逐列重算）。
-- 2 千列就夠：correlated SubPlan 會讓 loops 直接變成掃描列數，與 1 差了三個數量級；
-- 這裡不需要像 media 那樣的 5 萬列——那個數量級是為了驗索引選擇，不是驗 plan 形狀。
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select ('c1000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
       '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'perf-applicant-' || i || '@ls33.test', now(), now(), '{}', '{}'
  from generate_series(1, 5) i;

insert into public.profiles (id, display_name)
select ('c1000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, '效能測試申請人 ' || i
  from generate_series(1, 5) i;

insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at)
values ('1c000000-0000-4000-8000-000000000001', 'fc000000-0000-4000-8000-000000000001',
        'PERF2345', 'member', 'c0000000-0000-4000-8000-000000000001', 20,
        now() + interval '7 days');

-- 用 rejected 而不是 pending：join_requests_pending_unique 限制同一人對同一家庭只能有
-- 一筆 pending，要 2 千筆 pending 就得先造 2 千個帳號。policy 的 qual 不看 status，
-- 對 plan 形狀而言兩者等價。
insert into public.join_requests (family_id, invite_id, applicant_id, status, created_at)
select 'fc000000-0000-4000-8000-000000000001',
       '1c000000-0000-4000-8000-000000000001',
       ('c1000000-0000-4000-8000-' || lpad((1 + (i % 5))::text, 12, '0'))::uuid,
       'rejected', now() - (i * interval '1 minute')
  from generate_series(1, 2000) i;

-- LS-40：storage.objects 的 policy 是全 schema 唯一「不靠 family_id 欄位、靠路徑第一段」
-- 判家庭的一組，形狀與其他表不同（qual 左邊是 `(storage.foldername(name))[1]`），
-- 所以不能靠上面那幾條查詢代驗。2 萬列的理由同 join_requests：判的是 plan 形狀，
-- 空表上「loops=1」是恆真句。
-- bucket 'media' 由 20260823030000_storage_policies.sql 建立；storage.objects 上沒有
-- 任何可服務這條 qual 的索引（那張表不歸我們擁有，加不了索引），所以這裡預期看到
-- Seq Scan——本測試判的是「有沒有被逐列重算」，不是「有沒有走索引」。
--
-- 這裡也順帶說明那條 qual 為什麼用較慢的 storage.foldername()（本機實測 2 萬列：
-- foldername 36 ms、split_part 2.7 ms、path_tokens[1] 2.2 ms，基線 1.1 ms）：
-- 另外兩種寫法都得自己重述「第一段＝family」這個語義，或依賴 storage 自己的
-- generated 欄位，兩者都是環境相依的賭注（LS-15 教訓）。完整取捨寫在 migration
-- 那四條 policy 上方的註解，這裡不重複，只留指路。
insert into storage.objects (bucket_id, name, owner, owner_id, created_at)
select 'media',
       'fc000000-0000-4000-8000-000000000001/2026/'
         || lpad((1 + (i % 12))::text, 2, '0') || '/'
         || gen_random_uuid()::text || '.jpg',
       'c0000000-0000-4000-8000-000000000001',
       'c0000000-0000-4000-8000-000000000001',
       now() - (i * interval '1 minute')
  from generate_series(1, 20000) i;

analyze public.media;
analyze public.feed_items;
analyze public.family_members;
analyze public.join_requests;
analyze storage.objects;

do $$
declare
  v_n bigint;
begin
  select count(*) into v_n from public.media
   where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n < 50000 then
    raise exception 'FAIL：效能測試需要 ≥5 萬列，實際只有 %', v_n;
  end if;
  select count(*) into v_n from public.feed_items
   where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n < 50000 then
    raise exception 'FAIL：feed_items trigger 沒有跟上批量寫入，只有 % 列', v_n;
  end if;
  select count(*) into v_n from public.join_requests
   where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n < 2000 then
    raise exception 'FAIL：join_requests 的 plan 判準需要 ≥2000 列，實際只有 %（空表上 loops=1 是恆真句）', v_n;
  end if;
  select count(*) into v_n from storage.objects where bucket_id = 'media';
  if v_n < 20000 then
    raise exception 'FAIL：storage.objects 的 plan 判準需要 ≥2 萬列，實際只有 %', v_n;
  end if;
  raise notice 'ok：已灌入 5 萬列 media（feed_items 由 trigger 同步產生 5 萬列）、2 千列 join_requests、2 萬列 storage.objects';
end;
$$;

select set_config('request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  q record;
  v_line text;
  v_plan text;
  v_loops bigint;
begin
  for q in
    select * from (values
      ('主查詢 1：相簿格狀清單（帶 family_id）',
       'select id, storage_path, taken_at from public.media
         where family_id = ''fc000000-0000-4000-8000-000000000001'' and deleted_at is null
         order by created_at desc, id desc limit 50'),
      ('主查詢 2：只靠 RLS 過濾家庭（最嚴苛的情況）',
       'select id, storage_path from public.media
         where deleted_at is null
         order by created_at desc, id desc limit 50'),
      ('主查詢 3：時間軸 keyset 分頁',
       'select kind, ref_id, occurred_at from public.feed_items
         where family_id = ''fc000000-0000-4000-8000-000000000001''
           and (occurred_at, ref_id) < (now(), ''ffffffff-ffff-ffff-ffff-ffffffffffff''::uuid)
         order by occurred_at desc, ref_id desc limit 30'),
      -- LS-33：join_requests 的 policy 是本檔唯一一條「兩個 OR 分支」的 qual
      -- （applicant_id = auth.uid() 或 family_id in owned_family_ids()）。OR 兩側都要維持
      -- 一次性求值——只要有一側寫成內嵌子查詢，owner 的待審清單就會逐列重算。
      -- 這條清單的長度平時是個位數，所以慢下來不會有人察覺，直到某天不會。
      ('主查詢 4：加入申請清單（policy 有 OR 兩側）',
       'select id, family_id, applicant_id, status from public.join_requests
         order by created_at desc limit 50'),
      -- LS-40：Storage 的 policy 用 `(storage.foldername(name))[1] in (select f::text
      -- from private.family_ids() f)` 判家庭。這個子查詢一樣不引用外層資料列，
      -- 所以應該被收斂成 hashed SubPlan 一次求值；寫成 `exists (select 1 from
      -- private.family_ids() f where name like f::text || '/%')` 那種形狀就會變成
      -- 逐列 correlated SubPlan，這條查詢就是用來擋住那種改法的。
      ('主查詢 5：Storage 物件清單（policy 靠路徑第一段判家庭）',
       'select id, name from storage.objects
         where bucket_id = ''media''
         order by created_at desc limit 50')
      -- 主查詢 6（Storage 物件改寫，UPDATE 的 USING＋WITH CHECK）不放在這個迴圈裡：
      -- 它會真的 UPDATE 這 2 萬列，若跑在檔尾證據 EXPLAIN 之前，後面「證據 4：
      -- Storage 物件清單」量到的 buffers/cost 會摻進這次 UPDATE 留下的死元組
      -- （同一交易內死元組仍佔頁面，即使最終 rollback）。定點複驗 N4：搬到本檔
      -- 檔尾、所有證據 EXPLAIN 印完之後、真正 rollback 之前，見下方獨立的區塊。
    ) as t(label, stmt)
  loop
    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    if v_plan ~ '\(SubPlan [0-9]+\)' then
      raise exception E'FAIL 效能：% 的 plan 出現 per-row correlated SubPlan\n%', q.label, v_plan;
    end if;

    select coalesce(max((x[1])::bigint), 1) into v_loops
      from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
    if v_loops > 1 then
      raise exception E'FAIL 效能：% 的 plan 有節點被執行 % 次（policy 遭逐列重算）\n%',
        q.label, v_loops, v_plan;
    end if;

    raise notice 'ok 效能：% —— 無 correlated SubPlan，所有節點 loops=1', q.label;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 偵測器自我驗證：內嵌 aggregate／correlated 子查詢（PLAN §5 稱為必定逐列重算的形狀——
-- 子查詢引用外層資料列欄位且包在聚合函式內，規劃器無法拉平成 join）必須被抓到。
-- 偵測器判的是 plan 形狀，不是 SQL 寫法：等值形 IN/EXISTS 只有在被規劃器拉平成
-- hashed SubPlan 時才會過關，資料量大到超過 work_mem 時一樣會退化成逐列 SubPlan
-- 而被這裡擋下（見 PLAN §5）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_line text;
  v_plan text := '';
  v_loops bigint;
  v_bad_stmt text :=
    'select m.id from public.media m
      where m.deleted_at is null
        and (select count(*) from public.family_members fm
              where fm.family_id = m.family_id and fm.user_id = auth.uid()) > 0
      limit 50';
begin
  for v_line in execute 'explain (analyze) ' || v_bad_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;

  if v_plan !~ '\(SubPlan [0-9]+\)' and v_loops <= 1 then
    raise exception E'FAIL：偵測器失效——內嵌 correlated 子查詢竟然沒被判準抓到\n%', v_plan;
  end if;
  raise notice
    'ok 偵測器自我驗證：內嵌 correlated 子查詢被抓到（correlated SubPlan=%，最大 loops=%）',
    (v_plan ~ '\(SubPlan [0-9]+\)'), v_loops;
end;
$$;

-- ---------------------------------------------------------------------------
-- 證據輸出（run.sh 會把本檔案的輸出存成 evidence/explain_rls_plan.txt）
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== EXPLAIN 證據 1：media 清單（authenticated，5 萬列，帶 family_id）==='
explain (analyze, verbose, buffers)
select id, storage_path, taken_at from public.media
 where family_id = 'fc000000-0000-4000-8000-000000000001' and deleted_at is null
 order by created_at desc, id desc limit 50;

\echo ''
\echo '=== EXPLAIN 證據 2：media 清單（只靠 RLS 過濾家庭）==='
explain (analyze, verbose, buffers)
select id, storage_path from public.media
 where deleted_at is null
 order by created_at desc, id desc limit 50;

\echo ''
\echo '=== EXPLAIN 證據 3：feed_items keyset 分頁 ==='
explain (analyze, verbose, buffers)
select kind, ref_id, occurred_at from public.feed_items
 where family_id = 'fc000000-0000-4000-8000-000000000001'
   and (occurred_at, ref_id) < (now(), 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
 order by occurred_at desc, ref_id desc limit 30;

\echo ''
\echo '=== EXPLAIN 證據 4：Storage 物件清單（LS-40，2 萬列，policy 判路徑第一段）==='
explain (analyze, verbose, buffers)
select id, name from storage.objects
 where bucket_id = 'media'
 order by created_at desc limit 50;

\echo ''
\echo '=== 對照組：PLAN §5 稱為必定逐列重算的內嵌 aggregate／correlated 子查詢寫法（loops 會等於掃描列數）==='
explain (analyze)
select m.id from public.media m
 where m.deleted_at is null
   and (select count(*) from public.family_members fm
         where fm.family_id = m.family_id and fm.user_id = auth.uid()) > 0
 limit 50;

-- ---------------------------------------------------------------------------
-- 主查詢 6：Storage 物件改寫（UPDATE 的 USING＋WITH CHECK 一起求值）
--
-- LS-40 review F6：讀取那條（主查詢 5）只走 SELECT policy 的單一 qual。UPDATE 這條
-- 才會同時求值 USING 與 WITH CHECK，且 USING 裡有 OR 兩側（owned／uploader）與
-- owner 兩欄比對——那是全 schema 最複雜的一組 qual，沒有它就沒有任何 plan 判準看得到。
--
-- 判準歸因（哪一條在這裡真的吃重）：UPDATE 的 WITH CHECK 子計畫不會出現在任何
-- Filter 行裡（它們以裸的 `SubPlan N` 標籤掛在 Update 節點下），所以
-- 「plan 不得出現 (SubPlan N) 形式的 **qual 引用**」那條判準對它們是無效的；
-- 真正抓得到「WITH CHECK 被逐列重算」的是 loops=1 那條——correlated 的話
-- 那些 Function Scan 的 loops 會直接變成 2 萬。兩條判準在這裡分工不同，不是互為備援。
--
-- 定點複驗 N4：這條刻意搬到這裡（所有「證據」EXPLAIN 都印完之後、真正 rollback
-- 之前），不與主查詢 1-5 放在同一個判準迴圈裡——它會真的 UPDATE 這 2 萬列
-- storage.objects，同一交易內接下來的查詢仍看得到這次 UPDATE 留下的死元組
-- （MVCC 只在跨交易時才不可見），若排在「證據 4：Storage 物件清單」之前執行，
-- 量到的 buffers/cost 就不是乾淨的讀取基準。搬到這裡之後，證據 1-4 與對照組
-- 量到的都是這條 UPDATE 執行之前的乾淨狀態。
-- ---------------------------------------------------------------------------
do $$
declare
  v_line text;
  v_plan text := '';
  v_loops bigint;
  v_stmt text :=
    'update storage.objects
        set metadata = coalesce(metadata, ''{}''::jsonb) || ''{"ls40_plan_probe": true}''::jsonb
      where bucket_id = ''media''';
begin
  for v_line in execute 'explain (analyze, verbose, buffers) ' || v_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan ~ '\(SubPlan [0-9]+\)' then
    raise exception E'FAIL 效能：主查詢 6 的 plan 出現 per-row correlated SubPlan\n%', v_plan;
  end if;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
  if v_loops > 1 then
    raise exception E'FAIL 效能：主查詢 6 的 plan 有節點被執行 % 次（policy 遭逐列重算）\n%',
      v_loops, v_plan;
  end if;

  raise notice 'ok 效能：主查詢 6 —— 無 correlated SubPlan，所有節點 loops=1';
end;
$$;

-- ---------------------------------------------------------------------------
-- get_family_timeline（LS-48）效能回歸：merge-reviewer PR #60 review F1（major，
-- 本機實測證據）
--
-- 背景：get_family_timeline 原本用 `language sql` 包一句 `set search_path = ''`。
-- SET 子句是 Postgres 判斷「這支函式能不能被規劃器 inline」的已知阻斷條件——不能
-- inline，`(p_child_id is null or f.child_id = p_child_id)` 與游標比對的
-- `(cursor is null and cursor is null) or (row) < (row)` 這兩個 OR 條件就沒有機會被
-- 下推進 index cond，只能整段落在 Filter 逐列判斷。review 實測 20 萬列同一家庭：
-- 深頁分頁 3516 buffers、稀疏 child 第一頁 4638 buffers（同語意的手寫等值查詢只要
-- 4 buffers），本檔案上面新建的 feed_items_family_child_occurred_idx 從頭到尾沒被
-- 選用過。修法見 migration 對 get_family_timeline 的完整說明：改寫成 `language plpgsql`，
-- 依 p_child_id／游標是否為 NULL 拆成四條靜態查詢，每條都能被規劃器獨立求出走索引
-- 的 plan。
--
-- 與上面「主查詢」迴圈的分工：那個迴圈只驗 SubPlan／loops（policy 有沒有被逐列
-- 重算），對象是手寫 SQL，不是這支 RPC（review 原話：「現在 50_ 主查詢 3 測的是
-- 手寫 SQL，不是這支 RPC」）。這裡新增的判準是另一個維度——「索引有沒有被選對、
-- 掃描量是否與資料總量無關」，需要 buffers 與 Rows Removed by Filter，兩者都不是
-- 上面迴圈量的東西。
--
-- 驗法分兩層（EXPLAIN 對 plpgsql 函式呼叫是不透明的黑盒，外層看不到內層的
-- Index Cond——這是 Postgres 對函式呼叫節點的既有行為，不是本測試發明的假設）：
--   a) 直接對 RPC 呼叫本身做 EXPLAIN ANALYZE BUFFERS：Function Scan 節點會把內層
--      查詢實際跑掉的 buffers 彙總上來，斷言彙總值遠低於「壞掉的舊版」那個數量級
--      （門檻抓 60——比 review 實測的「手寫等值 4 buffers」留了十幾倍餘裕，用來
--      吸收環境差異／heap 沒有完美聚簇的正常波動，但離 3516／4638 那個數量級仍差了
--      兩個數量級以上，足以分辨「有沒有修好」）。
--   b) 另外直接 EXPLAIN 函式內部實際在跑的那兩段查詢文字（與 migration 裡
--      get_family_timeline 對應分支的 SQL **逐字一致**——之後修改任一分支的查詢
--      文字，這裡要同步改，否則驗到的不是真正部署的查詢，見下方每個探針前的
--      提醒）：驗 Index Cond 真的含 child_id／ROW 比較，且 Rows Removed by Filter
--      趨近於 0。
--
-- 資料量：效能家（fc）原本的 5 萬列 media 都沒有 child_id 可用；這裡另外準備
--   - 20 萬列合成的 diary 型別 feed_items（不經過 create_diary_entry／trigger，直接寫
--     feed_items——這張表對 diaries 本來就沒有外鍵，是已知且被接受的多型關聯設計，
--     見 init_schema.sql 對 feed_items 的註解），child_id 全部 NULL，用來撐出「深頁
--     分頁」的資料量；
--   - 5 列帶同一個 child_id、時間穿插在最新附近，模擬「稀疏 child 篩選」：20 萬多列
--     裡只有 5 列符合，若規劃器沒有真的選用 child 索引，篩選代價會跟資料總量成正比。
-- ---------------------------------------------------------------------------

-- 效能家（fc）原本沒有孩子；補一個給稀疏 child 篩選測試用
insert into public.children (id, family_id, name, birthday)
values ('2c000000-0000-4000-8000-000000000001', 'fc000000-0000-4000-8000-000000000001',
        '效能測試孩子', date '2025-01-01')
on conflict (id) do nothing;

insert into public.feed_items (family_id, kind, ref_id, occurred_at, child_id)
select 'fc000000-0000-4000-8000-000000000001', 'diary', gen_random_uuid(),
       now() - (i * interval '1 minute'), null
  from generate_series(1, 200000) i;

insert into public.feed_items (family_id, kind, ref_id, occurred_at, child_id)
select 'fc000000-0000-4000-8000-000000000001', 'diary', gen_random_uuid(),
       now() - (i * interval '17 minutes'), '2c000000-0000-4000-8000-000000000001'
  from generate_series(1, 5) i;

analyze public.feed_items;
analyze public.children;

do $$
declare
  v_line text;
  v_plan text;
  v_buffers bigint;
  v_removed bigint;
  v_deep_cursor constant timestamptz := now() - interval '150000 minutes';
  v_max_uuid constant uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  v_child constant uuid := '2c000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fc000000-0000-4000-8000-000000000001';
  -- review 實測壞掉的版本是 3516／4638 buffers；這裡留兩個數量級以上的餘裕，
  -- 但足以區分「有沒有修好」（見上方說明）。
  c_buffer_budget constant bigint := 60;
begin
  -- (a) 深頁分頁，透過真正的 RPC 呼叫（不篩 child）
  v_plan := '';
  for v_line in execute format(
    'explain (analyze, verbose, buffers) select * from public.get_family_timeline(%L::uuid, null, %L::timestamptz, %L::uuid, 20)',
    v_family, v_deep_cursor, v_max_uuid
  ) loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan ~ '\(SubPlan [0-9]+\)' then
    raise exception E'FAIL 效能：get_family_timeline 深頁分頁的 plan 出現 correlated SubPlan\n%', v_plan;
  end if;

  select coalesce(sum((x[1])::bigint), 0) into v_buffers
    from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
  if v_buffers > c_buffer_budget then
    raise exception E'FAIL 效能：get_family_timeline 深頁分頁 buffers=%（門檻 %）—— 疑似又退化成掃過整個 family 而不是索引直接定位到游標位置\n%',
      v_buffers, c_buffer_budget, v_plan;
  end if;
  raise notice 'ok 效能：get_family_timeline 深頁分頁（20 萬＋列，不篩 child） buffers=%（門檻 ≤%）',
    v_buffers, c_buffer_budget;

  -- (b) 稀疏 child 第一頁，透過真正的 RPC 呼叫
  v_plan := '';
  for v_line in execute format(
    'explain (analyze, verbose, buffers) select * from public.get_family_timeline(%L::uuid, %L::uuid, null, null, 20)',
    v_family, v_child
  ) loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan ~ '\(SubPlan [0-9]+\)' then
    raise exception E'FAIL 效能：get_family_timeline 稀疏 child 第一頁的 plan 出現 correlated SubPlan\n%', v_plan;
  end if;

  select coalesce(sum((x[1])::bigint), 0) into v_buffers
    from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
  if v_buffers > c_buffer_budget then
    raise exception E'FAIL 效能：get_family_timeline 稀疏 child 第一頁 buffers=%（門檻 %）—— 疑似又退化成逐列篩 child_id，而不是走 feed_items_family_child_occurred_idx\n%',
      v_buffers, c_buffer_budget, v_plan;
  end if;
  raise notice 'ok 效能：get_family_timeline 稀疏 child 第一頁（20 萬多列裡只有 5 列符合） buffers=%（門檻 ≤%）',
    v_buffers, c_buffer_budget;

  -- (c) 直接 EXPLAIN 函式內部「不篩 child、有游標」分支的原始查詢文字（與
  -- get_family_timeline 對應分支逐字一致），驗 Index Cond 真的含 ROW 比較
  v_plan := '';
  for v_line in execute format(
    $probe$explain (analyze, verbose, buffers)
      select f.kind, f.ref_id, f.occurred_at, f.child_id
        from public.feed_items f
       where f.family_id = %L::uuid
         and (f.occurred_at, f.ref_id) < (%L::timestamptz, %L::uuid)
       order by f.occurred_at desc, f.ref_id desc
       limit 20$probe$,
    v_family, v_deep_cursor, v_max_uuid
  ) loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan !~ 'Index Cond:.*ROW\(' then
    raise exception E'FAIL 效能：get_family_timeline 不篩 child 的游標分支沒有走到帶 ROW 比較的 Index Cond（可能又退化成 Seq Scan 或 Filter）\n%', v_plan;
  end if;
  raise notice 'ok 效能：不篩 child 的游標分支 Index Cond 含 ROW 比較（走 feed_items_family_occurred_idx）';

  -- (d) 直接 EXPLAIN 函式內部「篩 child、無游標」分支的原始查詢文字（與
  -- get_family_timeline 對應分支逐字一致），驗 Index Cond 含 child_id、且
  -- Rows Removed by Filter 趨近於 0
  v_plan := '';
  for v_line in execute format(
    $probe$explain (analyze, verbose, buffers)
      select f.kind, f.ref_id, f.occurred_at, f.child_id
        from public.feed_items f
       where f.family_id = %L::uuid
         and f.child_id = %L::uuid
       order by f.occurred_at desc, f.ref_id desc
       limit 20$probe$,
    v_family, v_child
  ) loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan !~ 'Index Cond:.*child_id' then
    raise exception E'FAIL 效能：get_family_timeline 篩 child 分支的 Index Cond 沒有含 child_id（可能沒有選用 feed_items_family_child_occurred_idx）\n%', v_plan;
  end if;

  select coalesce(sum((x[1])::bigint), 0) into v_removed
    from regexp_matches(v_plan, 'Rows Removed by Filter: ([0-9]+)', 'g') as x;
  if v_removed > 5 then
    raise exception E'FAIL 效能：get_family_timeline 篩 child 分支 Rows Removed by Filter=%（應趨近於 0，代表 child_id 真的被當成 index cond，而不是逐列 filter 掉）\n%',
      v_removed, v_plan;
  end if;
  raise notice 'ok 效能：篩 child 分支 Index Cond 含 child_id、Rows Removed by Filter=%（趨近於 0）', v_removed;
end;
$$;

rollback;
