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

analyze public.media;
analyze public.feed_items;
analyze public.family_members;

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
  raise notice 'ok：已灌入 5 萬列 media，feed_items 由 trigger 同步產生 5 萬列';
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
         order by occurred_at desc, ref_id desc limit 30')
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
-- 偵測器自我驗證：內嵌 correlated 子查詢（PLAN §5 明文禁止的寫法）必須被抓到
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
\echo '=== 對照組：PLAN §5 禁止的內嵌 correlated 子查詢寫法（loops 會等於掃描列數）==='
explain (analyze)
select m.id from public.media m
 where m.deleted_at is null
   and (select count(*) from public.family_members fm
         where fm.family_id = m.family_id and fm.user_id = auth.uid()) > 0
 limit 50;

rollback;
