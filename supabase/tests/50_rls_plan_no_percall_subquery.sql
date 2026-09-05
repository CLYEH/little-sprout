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

-- 5 萬列假照片（postgres 身分，繞過 RLS）。整個檔案跑在一個交易裡，結束 rollback，
-- 不留殘料。LS-204（LS-200 R1 i3 `ca99c6ae`；R2 merge-review B1 修正）：這個
-- insert 與 107_album_summaries.sql §6 原本各自維護一份幾乎一樣的 50000 列
-- fixture，抽成 00_fixtures.sql 建立的共用函式
-- `private.ls204_seed_media_perf_noise()`（見該函式定義旁的檔頭說明——R1 原本
-- 抽成獨立檔案用 psql `\ir` include，在 run.sh 的 docker-exec 連線管道下找不到
-- 檔案，已改用純 SQL 函式呼叫，三種連線管道天生一致）。函式呼叫仍在本檔自己
-- 的交易內執行、自己 rollback，執行次數與交易邊界都不變。
select private.ls204_seed_media_perf_noise();

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

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，on conflict do update
-- 蓋成這裡要的固定名稱（本檔只驗 plan 形狀，名稱本身不影響判準，但維持與其他
-- fixture 一致的慣例）。
insert into public.profiles (id, display_name)
select ('c1000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, '效能測試申請人 ' || i
  from generate_series(1, 5) i
on conflict (id) do update set display_name = excluded.display_name;

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

-- R1（LS-66 merge-reviewer PR #95 review M2）：children_select 自 R1 起是單一子查詢
-- `family_id in (select private.family_ids())`（跟主查詢 2 對 media 的 policy 同型），
-- 但這支表在本票之前完全沒有進過這個檔案——`list_children`（LS-66 新增，倚賴這條
-- policy 的 invoker RPC）比照 get_family_timeline／get_reaction_counts 的既有慣例，
-- 每一支倚賴 RLS 的新 invoker RPC 都該補一段迴歸，這裡補上，關掉 review 抓到的
-- gate 缺口。3 千列，量級同 join_requests（不需要 media 那種 5 萬列——那個量級是
-- 為了驗索引選擇，這裡只是要讓「loops=1」不是空表上的恆真句）。
insert into public.children (family_id, name, birthday)
select 'fc000000-0000-4000-8000-000000000001',
       '效能測試孩子 ' || i,
       date '2020-01-01' + (i % 2000)
  from generate_series(1, 3000) i;

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
analyze public.children;
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
  select count(*) into v_n from public.children
   where family_id = 'fc000000-0000-4000-8000-000000000001';
  if v_n < 3000 then
    raise exception 'FAIL：children 的 plan 判準需要 ≥3000 列，實際只有 %（空表上 loops=1 是恆真句）', v_n;
  end if;
  raise notice 'ok：已灌入 5 萬列 media（feed_items 由 trigger 同步產生 5 萬列）、2 千列 join_requests、2 萬列 storage.objects、3 千列 children';
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
         order by created_at desc limit 50'),
      -- R1（LS-66 merge-reviewer PR #95 review M2）：children_select 是
      -- `family_id in (select private.family_ids())` 這條單一子查詢（跟主查詢 2 對
      -- media 的 policy 同型）。直接查 `children` 表本身而不是透過 `list_children`——
      -- `list_children` 是 `language sql` 且帶 `set search_path = ''`，這樣的函式
      -- **不會被規劃器 inline**（原因見 `get_family_timeline` 在 API.md 的效能說明），
      -- EXPLAIN 對它只會看到一個不透明的 Function Scan 節點，看不進函式內部真正執行的
      -- 查詢、驗不到 policy 的 plan 形狀；直接對 `children` 下 SELECT 才是
      -- `list_children` 實際執行的查詢會產生的 plan，這裡驗的正是這條 plan。
      ('主查詢 6：孩子清單（children，list_children 倚賴的 policy）',
       'select id, name, deleted_at from public.children
         where family_id = ''fc000000-0000-4000-8000-000000000001''
         order by birthday, id limit 50')
      -- 主查詢 7（Storage 物件改寫，UPDATE 的 USING＋WITH CHECK）不放在這個迴圈裡：
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
-- 主查詢 7：Storage 物件改寫（UPDATE 的 USING＋WITH CHECK 一起求值）
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
-- 之前），不與主查詢 1-6 放在同一個判準迴圈裡——它會真的 UPDATE 這 2 萬列
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
    raise exception E'FAIL 效能：主查詢 7 的 plan 出現 per-row correlated SubPlan\n%', v_plan;
  end if;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
  if v_loops > 1 then
    raise exception E'FAIL 效能：主查詢 7 的 plan 有節點被執行 % 次（policy 遭逐列重算）\n%',
      v_loops, v_plan;
  end if;

  raise notice 'ok 效能：主查詢 7 —— 無 correlated SubPlan，所有節點 loops=1';
end;
$$;

-- ---------------------------------------------------------------------------
-- get_family_timeline（LS-48）效能回歸：merge-reviewer PR #60 review F1（major，
-- 第 1 輪）＋ N1（major，第 2 輪，gate 覆蓋面缺口）＋ N2（minor，門檻精準度）
--
-- 背景（第 1 輪 F1）：get_family_timeline 原本用 `language sql` 包一句
-- `set search_path = ''`。SET 子句是 Postgres 判斷「這支函式能不能被規劃器 inline」
-- 的已知阻斷條件——不能 inline，`(p_child_id is null or f.child_id = p_child_id)`
-- 與游標比對的 OR 條件就沒有機會被下推進 index cond，只能整段落在 Filter 逐列判斷。
-- review 實測 20 萬列同一家庭：深頁分頁 3516 buffers、稀疏 child 第一頁 4638
-- buffers（同語意的手寫等值查詢只要 4 buffers），本檔案新建的
-- feed_items_family_child_occurred_idx 從頭到尾沒被選用過。修法見 migration 對
-- get_family_timeline 的完整說明：改寫成 `language plpgsql`，依 p_child_id／游標是否
-- 為 NULL 拆成四條靜態查詢，每條都能被規劃器獨立求出走索引的 plan。
--
-- 第 2 輪 N1（gate 覆蓋面缺口，本段的直接理由）：第 1 輪的探針只涵蓋「分支 2（不篩
-- child、有游標）」與「分支 3（篩 child、無游標）」兩條——**分支 4（同時篩 child
-- 又帶游標）在兩個測試檔的任何一次呼叫裡都沒被真的執行過**；而探針 (c)/(d) EXPLAIN
-- 的是「手抄一份、宣稱與函式本體逐字一致」的 SQL 副本，不是函式本體本身，函式漂移
-- 不會讓這兩個探針變紅。reviewer 用 mutation 證實：只把分支 4 改成用 `asc` 排序＋
-- OR 條件（等同退回第 1 輪修復前的壞寫法），50_／85_ 兩個測試檔全綠不變——這兩個
-- 探針從未真的保護過分支 4。
--
-- 修法（不留人工同步的副本，兩害相權取其輕，選「全部走 RPC-level」這條路，
-- 不是 pg_get_functiondef() 文字對帳——理由見下）：
--   - 拿掉 (c)/(d) 兩支手抄 SQL 副本探針，四條分支**一律**透過真正呼叫
--     get_family_timeline() 本身來量测（不重寫一份「看起來一樣」的 SQL），從根本上
--     排除「副本與本體不同步」這個問題類別——不是把它修得更不容易忘記同步，是讓
--     「忘記同步」這件事不再可能發生。
--   - 每條分支都驗 buffers（遠低於「壞掉的舊版」那個數量級）＋沒有 correlated
--     SubPlan。buffers 是 reviewer 自己的 mutation 證實有效的判準（把分支 4 改壞
--     之後，若這裡量的是分支 4 本身的 buffers，會被抓到——這正是本段新增的內容）。
--   - 代價：EXPLAIN 對 plpgsql 函式呼叫是不透明的黑盒，看不到內層 Index Cond 字面
--     文字，所以「有沒有選用 feed_items_family_child_occurred_idx」這件事現在只靠
--     buffers 間接證明（掃描量與資料總量無關），不再直接斷言 Index Cond 字串。
--     這是刻意接受的取捨：直接斷言 Index Cond 字串需要文字副本才做得到，而文字副本
--     正是這次要拿掉的東西；buffers 已經是 mutation 驗證過「真的抓得到」的判準，
--     多一層字串比對不是抓得更準，是多一份要同步維護的重複資訊。
--
-- N2（門檻精準度）：第 1 輪門檻訂在 200，理由是「留兩個數量級以上餘裕」，但沒有
-- warm-up，量到的是**這個 session 第一次呼叫 plpgsql 函式**的成本（plpgsql 函式
-- 第一次執行要走 parse／plan cache 建置，是一次性成本，不是查詢本身的重複成本；
-- reviewer 實測首呼 187 buffers，200 的門檻只剩不到 10% 餘裕，環境一有風吹草動就會
-- 誤傷）。這裡在四條分支測試之前先呼叫一次（丟棄結果）暖機，把這個一次性成本挪到
-- warm-up 那一次去付，四條分支量到的都是「已經 warm」的穩定成本，門檻收緊到 120
-- 依然比 3516／4638 低了超過一個數量級。buffers 同時加總 `shared hit=` 與 `read=`
-- （第 1 輪只算了 hit——冷快取時的 `read=` 是真實發生的頁面存取，只算 hit 會低估
-- 實際 I/O 成本）。
--
-- 資料量：效能家（fc）原本的 5 萬列 media 都沒有 child_id 可用；這裡另外準備
--   - 20 萬列合成的 diary 型別 feed_items（不經過 create_diary_entry／trigger，直接寫
--     feed_items——這張表對 diaries 本來就沒有外鍵，是已知且被接受的多型關聯設計，
--     見 init_schema.sql 對 feed_items 的註解），完全不帶任何 diary_children 標記，
--     用來撐出「深頁分頁」的資料量、也代表「大部分內容其實沒有標記任何孩子」這個
--     常態。
--   - 150 天、每天 4 篇「真實」日記（600 篇），每篇標 2 個孩子——LS-121 R2
--     merge-reviewer PR #218 review M1：R1 版本只灌 5 列「稀疏」標記（20 萬列裡
--     只有 5 列符合），這批列全是合成 feed_items（沒有真實 diaries 列背書），
--     get_family_timeline 的 child_ids 聚合因此在 diary_children／album_children
--     上探到的永遠是空表——四條分支的 buffers 量到的不是本票新增的熱路徑，是一張
--     空表的成本。reviewer 實測「每篇日記都標 2 個孩子」是常態情境，不是邊界案例，
--     且篩 child、limit=20（產品預設）的真實成本達 136 buffers（原本的門檻只有
--     120）。這裡改灌真實資料集：`diary_children` 對 `diaries` 有外鍵，不能像
--     feed_items 那樣造假 ref_id，必須是真的 diaries 列——直接以 postgres 身分寫
--     `diaries`／`diary_children`（不經 `create_diary_entry`／`update_diary_entry`，
--     純粹是效能 fixture，同檔其他準備段落的既有慣例），INSERT 本身會觸發既有的
--     `feed_sync_diaries`／`feed_sync_diary_children` trigger 自動展開
--     `feed_items`／`feed_item_children`，不需要另外手動維護。時間跨度（150 天）
--     刻意蓋過 `v_deep_cursor_tagged`（見下方 DO 區塊）的深度，讓分支 4（篩 child
--     ＋帶游標）真的能回一整頁，不是像 R1 版本那樣游標落在整批資料的時間範圍之外、
--     回傳 0 列。
-- ---------------------------------------------------------------------------

-- 上面「主查詢 7」那段一路沿用檔案開頭的 `set local role authenticated;`（同一個
-- transaction 內持續有效，不會自己過期）。這裡的 fixture 準備（建孩子、灌 20 萬列
-- feed_items）需要繞過 RLS／grant，比照全檔其他 fixture 準備段落的慣例先切回
-- postgres，稍後呼叫 get_family_timeline 前再切回 authenticated。
reset role;

-- 兩個孩子：child_target 是分支 3／4 實際篩選的對象，child_cotag 是「每篇同時標
-- 第二個孩子」用（R1 起 fc 已因本檔上方 M2 迴歸多了 3000 個隨機 id 的 children，
-- 那批純粹是撐 children_select 的 plan 判準用、跟這裡完全無關；這裡固定 id 是因為
-- 下面要用同一個 id 反查標記資料）。
insert into public.children (id, family_id, name, birthday)
values
  ('2c000000-0000-4000-8000-000000000001', 'fc000000-0000-4000-8000-000000000001',
   '效能測試孩子（篩選目標）', date '2025-01-01'),
  ('2c000000-0000-4000-8000-000000000002', 'fc000000-0000-4000-8000-000000000001',
   '效能測試孩子（共同標記）', date '2025-01-02')
on conflict (id) do nothing;

insert into public.feed_items (family_id, kind, ref_id, occurred_at)
select 'fc000000-0000-4000-8000-000000000001', 'diary', gen_random_uuid(),
       now() - (i * interval '1 minute')
  from generate_series(1, 200000) i;

-- 標記資料集（見上方檔頭說明）。用暫存表而不是串接 CTE：`diaries` 的
-- INSERT 要先完整跑完、讓 `feed_sync_diaries` 的 AFTER STATEMENT trigger 展開
-- `feed_items` 之後，`diary_children` 的 INSERT 才能在自己的 `feed_sync_diary_
-- children` trigger 裡 join 到剛展開的 `feed_items` 列拿到 occurred_at——串在同一句
-- data-modifying CTE 裡，兩個 trigger 的執行時序沒有寫進 SQL 標準、不該依賴，拆成
-- 兩個獨立敘述才是這個依賴關係唯一乾淨的表達方式（同 migration 內 create_diary_
-- entry 先插 diaries、再插 diary_children 的既有兩步順序一致）。
create temporary table tmp_perf_tagged_diaries as
select gen_random_uuid() as id, current_date - d as entry_date
  from generate_series(1, 150) d, generate_series(1, 4) n;

insert into public.diaries (id, family_id, author_id, body, entry_date)
select id, 'fc000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001',
       '效能測試日記', entry_date
  from tmp_perf_tagged_diaries;

insert into public.diary_children (family_id, diary_id, child_id)
select 'fc000000-0000-4000-8000-000000000001', t.id, c.child_id
  from tmp_perf_tagged_diaries t
  cross join (values
    ('2c000000-0000-4000-8000-000000000001'::uuid),
    ('2c000000-0000-4000-8000-000000000002'::uuid)
  ) as c(child_id);

drop table tmp_perf_tagged_diaries;

-- LS-121 R3（merge-reviewer PR #218 review m3）：分支 1／2（不篩 child 的「全部」
-- 路徑，產品預設會先看到的視圖）回傳的頁面完全沒有標記列——標記資料集全部用
-- `entry_date`（日精度）換算 `occurred_at`，20 萬列合成 bulk 卻是 `now() - 分鐘`
-- 精度，同一天之內任何一列 bulk 都比當天的標記列新，兩條「不篩」分支的首頁／
-- 深頁因此只看得到 bulk。不需要重新設計整批 600 篇的時間分佈（分支 3／4 篩
-- child 已經在真實密度下驗過，見上方檔頭），只需要「至少 1 篇」標記內容能蓋過
-- bulk 最新端與 `v_deep_cursor` 附近——直接覆寫兩篇既有標記日記的 `occurred_at`
-- 成跟 bulk 同尺度的分鐘級時間戳：一篇蓋在 bulk 最新端（供分支 1 首頁吃到），
-- 一篇蓋在 `v_deep_cursor`（150000 分鐘）之後 1 分鐘處（供分支 2 深頁吃到，
-- `(occurred_at, ref_id) < 游標` 這個條件下一定落在該分支的第一列）。
-- `feed_items`／`feed_item_children` 兩張表的 `occurred_at` 都要同步覆寫——
-- 後者是前者的展開，兩者不同步會讓 88_deletion_attribution.sql 一類的既有測試
-- 對「兩者全程相等」的假設不成立（雖然那些測試不跑在這個 fixture 上，但沒有
-- 理由在這裡開一個先例）。
do $$
declare
  v_family constant uuid := 'fc000000-0000-4000-8000-000000000001';
  v_head_diary uuid;
  v_deep_diary uuid;
begin
  select id into v_head_diary from public.diaries
   where family_id = v_family and entry_date = current_date - 1
   order by id limit 1;
  update public.feed_items set occurred_at = now() - interval '1 minute'
   where kind = 'diary' and ref_id = v_head_diary;
  update public.feed_item_children set occurred_at = now() - interval '1 minute'
   where kind = 'diary' and ref_id = v_head_diary;

  select id into v_deep_diary from public.diaries
   where family_id = v_family and entry_date = current_date - 104
   order by id limit 1;
  update public.feed_items set occurred_at = now() - interval '150001 minutes'
   where kind = 'diary' and ref_id = v_deep_diary;
  update public.feed_item_children set occurred_at = now() - interval '150001 minutes'
   where kind = 'diary' and ref_id = v_deep_diary;

  if v_head_diary is null or v_deep_diary is null then
    raise exception 'FIXTURE FAIL：找不到用來覆寫 occurred_at 的標記日記（head=%，deep=%）', v_head_diary, v_deep_diary;
  end if;
end;
$$;

analyze public.diaries;
analyze public.diary_children;
analyze public.feed_items;
analyze public.feed_item_children;
analyze public.children;

-- 切回 authenticated（jwt claims 沿用檔案開頭已經 set_config 過的 c0000000...，
-- set_config 的設定不受 `set local role` 影響，仍然有效）：get_family_timeline 的
-- 授權判斷（feed_items 的 RLS）需要真的以 authenticated 身分呼叫才有意義。
set local role authenticated;

do $$
declare
  v_line text;
  v_plan text;
  v_buffers bigint;
  v_hit bigint;
  v_read bigint;
  v_deep_cursor constant timestamptz := now() - interval '150000 minutes';
  -- LS-121 R2（review M1）：分支 4 篩 child 的深頁游標要落在「標記資料集」自己的
  -- 150 天深度以內，不能沿用分支 2 那個對著 20 萬列合成 bulk（跨度 200000 分鐘
  -- ≈139 天）算出來的游標——R1 版本兩個分支共用同一個 v_deep_cursor，但標記資料集
  -- 當時只有 5 列、時間穿插在最新附近，深游標落在資料範圍外，分支 4 回傳的其實是
  -- 0 列（一次空的索引探查，不是一頁 20 列的成本，reviewer 實測指出）。這裡改用
  -- 專屬游標，對齊新資料集的天數座標（第 75 天，落在 1～150 天中段，兩側都還有
  -- 足夠列數，不會卡在邊界）。
  v_deep_cursor_tagged constant timestamptz := (current_date - 75)::timestamp at time zone 'utc';
  v_max_uuid constant uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  v_child constant uuid := '2c000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fc000000-0000-4000-8000-000000000001';
  -- LS-121 R2（review M1）：R1 的 120 是對著「child_ids 聚合探到空表」量出來的，
  -- 不是本票新增熱路徑的真實成本——改成真實標記資料集（見上方 fixture 說明）後，
  -- 實測四條分支穩定落在 30～140 buffers（篩 child 兩支分支的頁面每一列都要對
  -- diary_children 做 2 次 PK 查找，成本隨 p_limit 線性成長、與資料總量無關——
  -- reviewer 實測「篩 child，limit=20（產品預設）」136、「limit=100」406，
  -- 約 3–7 buffers/列；這個形狀本身是健康的 keyset 行為，200 這個門檻只是給這個
  -- 健康形狀足夠餘裕，不是在放寬對「退化成掃全表／退化成先 join 再排序」的偵測——
  -- 那種退化是數量級級的（R1 review 實測壞掉的版本 3516／4638），200 依然低了一個
  -- 數量級以上）。
  c_buffer_budget constant bigint := 200;
  q record;
begin
  -- warm-up：session 第一次呼叫 plpgsql 函式有一次性的 parse／plan cache 建置成本
  -- （reviewer 實測 187 buffers），與查詢本身的重複成本是兩回事。這裡先呼叫一次、
  -- 丟棄結果，讓下面四條分支量到的都是暖機之後的穩定成本，門檻才立得住意義。
  perform * from public.get_family_timeline(v_family, null, null, null, 1);

  -- 四條分支「一律」透過真正呼叫 get_family_timeline() 本身量測（N1：不留手抄 SQL
  -- 副本）。分支 4（篩 child＋帶游標）是 LS-48 review 第 2 輪新補的——第 1 輪只驗過
  -- 分支 2／3。
  --
  -- LS-121 R2（review M1）：拿掉了原本的 `if v_plan ~ '\(SubPlan [0-9]+\)'` 斷言——
  -- 這條對 plpgsql 函式呼叫恆為偽，不是門檻鬆了。reviewer 實測：
  -- `explain (analyze, verbose, buffers) select * from get_family_timeline(...)`
  -- 的完整輸出就是單一行 `Function Scan on public.get_family_timeline (...)`，
  -- EXPLAIN 不會下鑽進 plpgsql 函式本體，本票新增的 correlated 子查詢（child_ids
  -- 聚合）永遠不會被外層 EXPLAIN 看見，這條斷言從第一天就測不到任何東西、也不可能
  -- 測到——不是本票造成的退化，是移除一個從未真的生效過的假防線，誠實反映「這四條
  -- 分支的實質防線只剩 buffers」（見上方 c_buffer_budget 說明），不留一條看起來
  -- 在把關、實際上是恆真句的斷言。
  for q in
    select * from (values
      (1, '分支 1：不篩 child、無游標（首頁）',
       format('select * from public.get_family_timeline(%L::uuid, null, null, null, 20)',
         v_family)),
      (2, '分支 2：不篩 child、有游標（深頁分頁）',
       format('select * from public.get_family_timeline(%L::uuid, null, %L::timestamptz, %L::uuid, 20)',
         v_family, v_deep_cursor, v_max_uuid)),
      (3, '分支 3：篩 child、無游標（第一頁，資料集見上方 fixture 說明）',
       format('select * from public.get_family_timeline(%L::uuid, %L::uuid, null, null, 20)',
         v_family, v_child)),
      (4, '分支 4：篩 child、有游標（深頁，落在標記資料集的第 75 天）',
       format('select * from public.get_family_timeline(%L::uuid, %L::uuid, %L::timestamptz, %L::uuid, 20)',
         v_family, v_child, v_deep_cursor_tagged, v_max_uuid))
    ) as t(idx, label, stmt)
    order by idx
  loop
    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    -- N2：buffers 同時加總 shared hit= 與 read=（不只算 hit，冷快取的 read= 一樣是
    -- 真實發生的頁面存取，只算 hit 會低估實際 I/O 成本）。
    select coalesce(sum((x[1])::bigint), 0) into v_hit
      from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
    select coalesce(sum((x[1])::bigint), 0) into v_read
      from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;
    v_buffers := v_hit + v_read;

    if v_buffers > c_buffer_budget then
      raise exception E'FAIL 效能：get_family_timeline %（分支 %）buffers=%（hit=% read=%，門檻 %）—— 疑似索引沒被正確選用，掃描量與資料總量成正比而不是與 limit 成正比\n%',
        q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget, v_plan;
    end if;

    -- 分支 3／4 的頁面應該全部命中標記資料集（每列 kind=diary、真的走 diary_children
    -- 聚合），不是 0 列的空探查——R1 review 的核心指控就是「分支 4 回傳 0 列」，這裡
    -- 補一個正向斷言，之後有人不小心讓游標又跑到資料範圍外會直接紅，不必等人工複查
    -- buffers 數字才發現。
    if q.idx in (3, 4) then
      declare
        v_rowcount int;
      begin
        execute 'select count(*) from (' || q.stmt || ') t' into v_rowcount;
        if v_rowcount = 0 then
          raise exception 'FAIL 效能：get_family_timeline %（分支 %）回傳 0 列——游標或資料集範圍算錯了，這條分支量到的是空探查不是一頁真實資料', q.label, q.idx;
        end if;
      end;
    end if;

    -- LS-121 R3（review m3）：分支 1／2（不篩 child）的頁面必須至少有 1 列帶標記，
    -- 不然 child_ids 聚合在這兩條分支量到的一樣是空探查——見上方 fixture 準備段落
    -- 對兩篇標記日記 occurred_at 的覆寫。之後有人不小心把那段覆寫弄丟（或改壞
    -- fixture 的時間座標）會直接紅，不必等人工複查 buffers 數字才發現。
    if q.idx in (1, 2) then
      declare
        v_tagged_rowcount int;
      begin
        execute 'select count(*) from (' || q.stmt || ') t where array_length(t.child_ids, 1) > 0'
          into v_tagged_rowcount;
        if v_tagged_rowcount = 0 then
          raise exception 'FAIL 效能：get_family_timeline %（分支 %）整頁都沒有帶標記的列——child_ids 聚合在「全部」路徑上量到的還是空探查，不是本票新增的熱路徑', q.label, q.idx;
        end if;
      end;
    end if;

    raise notice 'ok 效能：get_family_timeline %（分支 %） buffers=%（hit=% read=%，門檻 ≤%）',
      q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_family_timeline（v_has_blocks=true 路徑）效能守門：LS-149 R2（merge-reviewer
-- PR #248 R1 minor-1）
--
-- 上面那個 DO 區塊全程用 c0000000...001（效能測試帳號）呼叫，這個帳號沒有封鎖過任何
-- 人，所以四條分支量到的一律是 v_has_blocks=false 變體——LS-149 新增的、風險已知
-- 較高的 v_has_blocks=true 變體（NOT EXISTS + private.feed_item_actor_id() 逐列查找，
-- 見 20260903091317_report_block_rpc.sql 對 get_family_timeline 的說明）完全沒被量過、
-- 也沒有任何 buffers 上限守著它。
--
-- reviewer（merge-review R1）實測：在本檔案這組資料集（600 列標記資料）上，篩 child、
-- 無游標那條分支（分支 3）的 v_has_blocks=true 版本要 1881 buffers（比 v_has_blocks=
-- false 版本的 136 高一個數量級），但把候選子集合拉到 6000 列之後規劃器改選
-- `Nested Loop Anti Join` ＋ `Index Scan using feed_item_children_family_child_occurred_idx`
-- ＋提早 LIMIT，buffers 反而降到 143——代表壞成本只發生在「候選集合小到規劃器認為
-- 整段掃比較划算」的中間帶，不是隨資料量線性成長。門檻因此刻意訂得比
-- v_has_blocks=false 那組（200）寬很多（下面的 2500）：這裡要擋的是「有人動
-- `feed_item_actor_id()` 或那四段 `NOT EXISTS` 之後，這條路徑退化到數千至數萬 buffers」
-- 這種數量級級的劣化，不是要求它跟常見路徑一樣緊——那條路徑本來就刻意接受較高成本
-- （見 migration 檔頭「2. get_family_timeline」段落的設計裁量）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_line text;
  v_plan text;
  v_buffers bigint;
  v_hit bigint;
  v_read bigint;
  v_deep_cursor constant timestamptz := now() - interval '150000 minutes';
  v_deep_cursor_tagged constant timestamptz := (current_date - 75)::timestamp at time zone 'utc';
  v_max_uuid constant uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  v_child constant uuid := '2c000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fc000000-0000-4000-8000-000000000001';
  -- 見上方檔頭說明：故意比 v_has_blocks=false 那組（200）寬很多，只擋數量級退化。
  c_buffer_budget constant bigint := 2500;
  q record;
  v_rowcount int;
begin
  -- 讓效能測試帳號真的封鎖一個人，觸發 get_family_timeline 內部的 v_has_blocks=true
  -- 分支——blocked_id 不必是這個家庭的成員（block_user／blocked_users 本來就不驗證這件
  -- 事，見 migration 設計裁量第 3 點），借用效能資料集本來就有的 2 千個合成 profile
  -- （join_requests 準備段落建立，見上方 fixture 說明）任取一個即可。整份 50_ 檔案跑在
  -- 一個交易裡（檔頭 `begin;`），這裡不需要另開交易，檔尾的 `rollback;` 會一併復原。
  reset role;
  insert into public.blocked_users (family_id, blocker_id, blocked_id)
  values (v_family, 'c0000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001');

  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  -- 這是這個 session 第一次執行 v_has_blocks=true 分支（跟上面 false 分支是不同的
  -- 靜態查詢、不同的 plan cache 項目），warm-up 一次丟棄結果，理由同上面 N2 說明。
  perform * from public.get_family_timeline(v_family, v_child, null, null, 1);

  for q in
    select * from (values
      (1, '分支 1（v_has_blocks=true）：不篩 child、無游標（首頁）',
       format('select * from public.get_family_timeline(%L::uuid, null, null, null, 20)',
         v_family)),
      (2, '分支 2（v_has_blocks=true）：不篩 child、有游標（深頁分頁）',
       format('select * from public.get_family_timeline(%L::uuid, null, %L::timestamptz, %L::uuid, 20)',
         v_family, v_deep_cursor, v_max_uuid)),
      (3, '分支 3（v_has_blocks=true）：篩 child、無游標（第一頁）',
       format('select * from public.get_family_timeline(%L::uuid, %L::uuid, null, null, 20)',
         v_family, v_child)),
      (4, '分支 4（v_has_blocks=true）：篩 child、有游標（深頁）',
       format('select * from public.get_family_timeline(%L::uuid, %L::uuid, %L::timestamptz, %L::uuid, 20)',
         v_family, v_child, v_deep_cursor_tagged, v_max_uuid))
    ) as t(idx, label, stmt)
    order by idx
  loop
    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    select coalesce(sum((x[1])::bigint), 0) into v_hit
      from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
    select coalesce(sum((x[1])::bigint), 0) into v_read
      from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;
    v_buffers := v_hit + v_read;

    if v_buffers > c_buffer_budget then
      raise exception E'FAIL 效能：get_family_timeline %（分支 %）buffers=%（hit=% read=%，門檻 %）—— v_has_blocks=true 這條路徑退化到數量級以上的成本，疑似 private.feed_item_actor_id() 或封鎖過濾的 NOT EXISTS 被改壞\n%',
        q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget, v_plan;
    end if;

    -- 正向對照：確認量到的是一頁真實資料，不是因為封鎖過濾把整頁篩空的空探查
    -- （c1000000...001 不是任何一列的作者，理論上不會濾掉任何東西，回傳列數應與
    -- v_has_blocks=false 那組相同）。
    execute 'select count(*) from (' || q.stmt || ') t' into v_rowcount;
    if v_rowcount = 0 then
      raise exception 'FAIL 效能：get_family_timeline %（分支 %）回傳 0 列——v_has_blocks=true 分支量到的是空探查，不是一頁真實資料', q.label, q.idx;
    end if;

    raise notice 'ok 效能：get_family_timeline %（分支 %） buffers=%（hit=% read=%，門檻 ≤%，v_has_blocks=true）',
      q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- list_comments（LS-58）效能回歸：同一個教訓（LS-48 F1）再套一次——比照
-- get_family_timeline 拆成「無游標／有游標」兩條靜態查詢，避免 OR 條件擋掉
-- comments_target_idx（family_id, target_type, target_id, created_at）的索引選用。
--
-- 資料量：5 萬則留言全部掛在**同一個** target 上（單一相簿/照片吃到 5 萬則留言在
-- 產品上不現實，但這正是要驗的東西——分頁查詢的 buffers 必須跟 limit 成正比，
-- 不能跟這個 target 底下的留言總數成正比；用一個極端值才測得出退化成全表掃描的
-- 情況會有多糟）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_target constant uuid := '3c000000-0000-4000-8000-000000000001';
  v_n bigint;
begin
  reset role;
  insert into public.comments (family_id, target_type, target_id, author_id, body, created_at)
  select 'fc000000-0000-4000-8000-000000000001', 'media', v_target,
         'c0000000-0000-4000-8000-000000000001', 'list_comments 效能測試 #' || i,
         now() - (i * interval '1 minute')
    from generate_series(1, 50000) i;
  analyze public.comments;

  select count(*) into v_n from public.comments
   where target_type = 'media' and target_id = v_target;
  if v_n < 50000 then
    raise exception 'FAIL：list_comments 效能測試需要 ≥5 萬則留言，實際只有 %', v_n;
  end if;

  set local role authenticated;
  perform * from public.list_comments(
    'fc000000-0000-4000-8000-000000000001', 'media', v_target, null, null, 1);  -- warm-up
end;
$$;

do $$
declare
  v_line text;
  v_plan text;
  v_buffers bigint;
  v_hit bigint;
  v_read bigint;
  v_target constant uuid := '3c000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fc000000-0000-4000-8000-000000000001';
  v_deep_cursor constant timestamptz := now() - interval '49900 minutes';
  v_max_uuid constant uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  -- 同一套暖機後穩定成本邏輯與門檻取法，見上方 get_family_timeline 段落的 N2 說明。
  c_buffer_budget constant bigint := 60;
  q record;
begin
  for q in
    select * from (values
      (1, '分支 1：無游標（第一頁）',
       format('select * from public.list_comments(%L::uuid, ''media'', %L::uuid, null, null, 20)',
         v_family, v_target)),
      (2, '分支 2：有游標（深頁分頁）',
       format('select * from public.list_comments(%L::uuid, ''media'', %L::uuid, %L::timestamptz, %L::uuid, 20)',
         v_family, v_target, v_deep_cursor, v_max_uuid))
    ) as t(idx, label, stmt)
    order by idx
  loop
    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    if v_plan ~ '\(SubPlan [0-9]+\)' then
      raise exception E'FAIL 效能：list_comments %（分支 %）的 plan 出現 correlated SubPlan\n%',
        q.label, q.idx, v_plan;
    end if;

    select coalesce(sum((x[1])::bigint), 0) into v_hit
      from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
    select coalesce(sum((x[1])::bigint), 0) into v_read
      from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;
    v_buffers := v_hit + v_read;

    if v_buffers > c_buffer_budget then
      raise exception E'FAIL 效能：list_comments %（分支 %）buffers=%（hit=% read=%，門檻 %）—— 疑似索引沒被正確選用，掃描量與這個 target 底下的留言總數（5 萬）成正比而不是與 limit 成正比\n%',
        q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget, v_plan;
    end if;

    raise notice 'ok 效能：list_comments %（分支 %） buffers=%（hit=% read=%，門檻 ≤%）',
      q.label, q.idx, v_buffers, v_hit, v_read, c_buffer_budget;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_reaction_counts（LS-58）：單一靜態聚合查詢（無 OR／游標分支），跟主查詢
-- 1-5 同一套判準（無 correlated SubPlan、所有節點 loops=1）即可，不需要另立
-- get_family_timeline／list_comments 那種暖機＋buffer 門檻的專屬段落——那兩支
-- 有「拆成多條靜態查詢」的 inline 風險（LS-48 F1 教訓），這支沒有。
--
-- 資料量：250 個不同 target，每個各 20 筆反應（5000 筆總計），共用 20 個效能帳號
-- （reactions 的 UNIQUE(target_type, target_id, user_id) 限制同一人對同一 target
-- 只能一筆，跨 target 可重複用同一批使用者）。查詢只帶其中 20 個 target_id，
-- 驗證 buffers／plan 不會跟 5000 筆總量成正比。
-- ---------------------------------------------------------------------------
do $$
declare
  v_targets uuid[];
  v_n bigint;
begin
  reset role;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select ('c2000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
         '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'perf-reactor-' || i || '@ls58.test', now(), now(), '{}', '{}'
    from generate_series(1, 20) i
   on conflict (id) do nothing;

  -- LS-110：改成 do update（原本的 do nothing 在 trigger 已自動建列的情況下會讓
  -- display_name 停留在 trigger 推導出的值，而不是這裡想要的固定名稱）。
  insert into public.profiles (id, display_name)
  select ('c2000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, '效能測試反應者 ' || i
    from generate_series(1, 20) i
   on conflict (id) do update set display_name = excluded.display_name;

  select array_agg(('4c000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid)
    into v_targets
    from generate_series(1, 250) i;

  insert into public.reactions (family_id, target_type, target_id, user_id)
  select 'fc000000-0000-4000-8000-000000000001', 'album', t, u
    from unnest(v_targets) as t
   cross join lateral (
     select ('c2000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as u
       from generate_series(1, 20) i
   ) users;
  analyze public.reactions;

  select count(*) into v_n from public.reactions
   where family_id = 'fc000000-0000-4000-8000-000000000001' and target_type = 'album';
  if v_n < 5000 then
    raise exception 'FAIL：get_reaction_counts 效能測試需要 ≥5000 筆反應，實際只有 %', v_n;
  end if;

  set local role authenticated;
end;
$$;

do $$
declare
  v_line text;
  v_plan text := '';
  v_loops bigint;
  v_stmt text := 'select * from public.get_reaction_counts(''fc000000-0000-4000-8000-000000000001''::uuid, ''album'', (select array_agg((''4c000000-0000-4000-8000-'' || lpad(i::text, 12, ''0''))::uuid) from generate_series(1, 20) i))';
begin
  for v_line in execute 'explain (analyze, verbose, buffers) ' || v_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan ~ '\(SubPlan [0-9]+\)' then
    raise exception E'FAIL 效能：get_reaction_counts 的 plan 出現 per-row correlated SubPlan\n%', v_plan;
  end if;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
  if v_loops > 1 then
    raise exception E'FAIL 效能：get_reaction_counts 的 plan 有節點被執行 % 次\n%', v_loops, v_plan;
  end if;

  raise notice 'ok 效能：get_reaction_counts —— 無 correlated SubPlan，所有節點 loops=1';
end;
$$;

rollback;
