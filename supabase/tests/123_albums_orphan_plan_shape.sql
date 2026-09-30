-- LS-412：albums 孤兒集合的 plan-shape 常設 gate（LS-408 R1 i1／LS-409 R1 i3）
--
-- 背景：`albums_update` policy 的 owner 分支與 `set_album_children` 的授權都走
-- `id in (select private.owned_orphan_album_ids())`（LS-409）。這條寫法之所以安全，
-- 前提是規劃器把它收斂成 **hashed SubPlan、每個 statement 只算一次**；一旦被改成逐列
-- EXISTS，或把集合包進 SECURITY DEFINER 函式做逐列呼叫（例如
-- `private.is_orphan_album(id)`，LS-409 取捨 a(i) 否決的寫法），每列都會重算「owner 家庭內
-- 全部孤兒相簿」，成本變成相簿數的平方。LS-408 migration 註解宣稱這件事由 tests/50 的偵測機制
-- 覆蓋，但 tests/50 沒有任何 albums 查詢——本檔補上，判準沿用 tests/50（loops 只能從
-- ANALYZE 取）並加一條專為「逐列函式呼叫」設的：
--   1. plan 不得出現 `(SubPlan N)` 形式的 qual 引用（correlated、逐列）；
--   2. 所有節點 loops 必須是 1；
--   3. **孤兒集合本身**必須是 hashed SubPlan：plan 裡要找得到 `Output:
--      private.owned_orphan_album_ids()` 的 SubPlan，且 Filter 以 `hashed SubPlan N` 引用它。
--      不能只問「plan 裡有沒有任何 hashed SubPlan」——作者分支的 `contributor_family_ids()`
--      就會產生一個，LS-412 R1 merge-review M1 的 M5 mutation 正是這樣騙過第一版：
--      SECURITY DEFINER 函式不會被 inline，逐列函式呼叫在 plan 上只是 Filter 裡的一個
--      函式呼叫，沒有 `(SubPlan N)`、所有 loops=1，孤兒集合（函式內部）對 plan 不可見，
--      實測 5000 列相簿建了 5001 次集合（乾淨是 2 次）。判準 3 抓的就是「孤兒集合從
--      plan 上消失」。
--
--   4. **函式呼叫計數**（LS-412 R3）：`set local track_functions = 'all'` 後，每條 statement
--      前後取 `pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure)`
--      的差值——owner 情境 ≤2（USING 與 WITH CHECK 各建一次）、作者本人 by-id 0、S3 ≤1，
--      且 owner 情境 ≥1（計數器真的在數，不是恆 0）。判準 3 看的是 plan 形狀，抓不到「孤兒集合
--      仍以 hashed SubPlan 出現、另外再多一處逐列包裝呼叫同函式」的寫法（LS-412 R2 merge-review
--      M6：保留 hashed 集合＋另加逐列包裝，實測 1669 次呼叫、判準 1–3 全綠），只有計數抓得到。
--      `track_functions` 是 superuser-only GUC，但 supautils 的 `privileged_role_allowed_configs`
--      有列它、postgres 是 supabase_privileged_role 成員，所以 **在交易最上層** 用 SET LOCAL 可設；
--      在 DO 區塊裡用 `set_config()` 設、或在 `set local role authenticated` **之後**才設，
--      都會得到 `permission denied to set parameter "track_functions"`（R2 我先撞到後者
--      而誤判「不可用」）。所以本檔的 SET LOCAL 一定要放在最上層、任何 `set local role` 之前。
--
-- 為什麼是新檔而不是塞進 tests/50：tests/50 先灌 5 萬列 media＋2 萬列 storage.objects，
-- 本檔只需要 5000 列 albums，獨立跑快得多；判準與 tests/50 一字不差。
--
-- 三情境（票文範圍 1）：
--   S1 作者本人 update（a2，非 owner）：OR 的作者分支成立；孤兒集合對 a2 是空集合。
--   S2 owner 對非己相簿 update（a1）：走孤兒分支，USING 與 WITH CHECK 各建一次孤兒
--      id 雜湊表（LS-409 R1 i3：owner update 建集合兩次，成本與「家庭相簿數」成正比，
--      不隨列數放大；5000 列時各約 1 ms，本檔不改 policy，只把這件事記在這裡與 API.md §3）。
--   S3 `set_album_children` owner 呼叫（孤兒相簿，空陣列，不寫任何列）：函式內是 plpgsql，
--      EXPLAIN 看不進去，改實際呼叫並用判準 4 計數（≤1、≥1）——量的是函式本體真正跑的授權式，
--      不再手抄表達式（S3(b)）、也不再比對函式本體字面（S3(a)）（LS-412 R1 i2 收掉：字面比對
--      改寫成 `IN (SELECT` 就會誤報、且抓不到語意不同的改寫）。
-- 另加 catalog 斷言：`private.owned_orphan_album_ids()` 必須是 STABLE。實測（本機 PG）
-- 把它改成 VOLATILE 時 plan 形狀不變（仍是 hashed SubPlan、loops=1），所以 plan 判準
-- 抓不到這個退步，只有這條 catalog 斷言抓得到——兩者分工，不是互為備援。
--
-- Mutation 自證（本票實跑，斷言原文見 PR 描述／handoff）：
--   M1 `private.owned_orphan_album_ids()` 改 VOLATILE（catalog 斷言紅）；
--   M2 albums_update 的 owner 分支改成逐列 count(*) 相關子查詢（plan 判準紅）；
--   M3 set_album_children 授權式改寫成呼叫兩次集合（S3 計數 >1 紅；R3 前是 S3(a) 字面斷言紅）；
--   M5（R2）新增 SECURITY DEFINER STABLE 包裝 `private.ls412_is_orphan(id)`（本體
--      `id in (select owned_orphan_album_ids())`），policy owner 分支改 `or ls412_is_orphan(id)`
--      → 判準 3 紅。檔尾偵測器自我驗證段以同一寫法當 negative control；
--   M6（R3）保留 hashed 集合、policy 另加 `or private.ls412_m6_wrap(id)` 逐列包裝 → 判準 1–3
--      全綠，只有判準 4 計數紅；檔尾偵測器自我驗證 #3 以同一寫法當 negative control。

\set ON_ERROR_STOP on

begin;

-- 判準 4 的計數器：必須在交易最上層、任何 set local role 之前（見檔頭），不可搬進 DO 區塊。
set local track_functions = 'all';

-- 5000 列 A 家相簿：作者三分之一 a2（member）、三分之一 a1（owner）、三分之一 NULL（孤兒）。
-- postgres 身分寫入（繞過 RLS）；整個檔案跑在一個交易裡，結束 rollback，不留殘料。
insert into public.albums (family_id, title, created_by)
select 'fa000000-0000-4000-8000-000000000001',
       'ls412 plan ' || i,
       case i % 3
         when 0 then 'a0000000-0000-4000-8000-000000000002'::uuid
         when 1 then 'a0000000-0000-4000-8000-000000000001'::uuid
         else null
       end
  from generate_series(1, 5000) i;

analyze public.albums;

do $$
declare
  v_n bigint;
  v_orphans bigint;
begin
  select count(*) into v_n from public.albums
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  select count(*) into v_orphans from public.albums
   where family_id = 'fa000000-0000-4000-8000-000000000001' and created_by is null;
  if v_n < 5000 or v_orphans < 1000 then
    raise exception 'FAIL：plan 判準需要 ≥5000 列相簿、≥1000 列孤兒，實際 % 列／% 孤兒（空集合上 loops=1 是恆真句）',
      v_n, v_orphans;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 判準 3 的解析器（pg_temp，隨交易消失）：從 verbose plan 找出「Output 為
-- private.owned_orphan_album_ids() 的 SubPlan」編號，確認 Filter 有以 `hashed SubPlan N`
-- 引用其中之一。回傳空字串＝通過，否則為失敗原因。
-- ---------------------------------------------------------------------------
create function pg_temp.ls412_orphan_check(p_plan text) returns text
language plpgsql as $f$
declare
  v_line text;
  v_cur int;
  v_found int[] := array[]::int[];
  v_n int;
begin
  foreach v_line in array string_to_array(p_plan, E'\n') loop
    if v_line ~ '^\s*SubPlan [0-9]+\s*$' then
      v_cur := (regexp_match(v_line, 'SubPlan ([0-9]+)'))[1]::int;
    elsif v_line ~ '^\s*(InitPlan|SubPlan) ' or v_line ~ '^\S' then
      v_cur := null;
    elsif v_cur is not null and v_line ~ 'Output: private\.owned_orphan_album_ids\(\)' then
      v_found := v_found || v_cur;
    end if;
  end loop;

  if coalesce(array_length(v_found, 1), 0) = 0 then
    return '孤兒集合 private.owned_orphan_album_ids() 在 plan 上找不到對應的 SubPlan——判定被包進逐列函式呼叫或其他不可見的形狀';
  end if;
  foreach v_n in array v_found loop
    if p_plan ~ ('hashed SubPlan ' || v_n || '\)') then
      return '';
    end if;
  end loop;
  return format('孤兒集合的 SubPlan %s 沒有被 Filter 以 hashed SubPlan 引用（不是單次求值的雜湊子計畫）', v_found);
end;
$f$;

-- ---------------------------------------------------------------------------
-- catalog：孤兒集合函式必須 STABLE（plan 形狀看不出 VOLATILE，見檔頭）
-- ---------------------------------------------------------------------------
do $$
declare
  v_vol "char";
begin
  select p.provolatile into v_vol from pg_proc p
   where p.oid = 'private.owned_orphan_album_ids()'::regprocedure;
  if v_vol <> 's' then
    raise exception 'FAIL 效能：private.owned_orphan_album_ids() 的 provolatile=%（必須是 s＝STABLE）', v_vol;
  end if;
  raise notice 'ok catalog：owned_orphan_album_ids() 是 STABLE';
end;
$$;

-- ---------------------------------------------------------------------------
-- plan 判準＋計數判準：四條 update（S1、S2 各 批次＋by-id 兩種形狀）
-- ---------------------------------------------------------------------------
do $$
declare
  v_a2_album uuid;
  v_orphan_album uuid;
  q record;
  v_line text;
  v_plan text;
  v_loops bigint;
  v_why text;
  v_before bigint;
  v_calls bigint;
begin
  select id into v_a2_album from public.albums
   where title like 'ls412 plan %' and created_by = 'a0000000-0000-4000-8000-000000000002' limit 1;
  select id into v_orphan_album from public.albums
   where title like 'ls412 plan %' and created_by is null limit 1;

  for q in
    select * from (values
      ('S1 作者本人批次 update（a2）', 'a0000000-0000-4000-8000-000000000002',
       'update public.albums set title = title where title like ''ls412 plan %''', 0, 2),
      ('S1b 作者本人 by-id update（a2，PostgREST 形狀）', 'a0000000-0000-4000-8000-000000000002',
       format('update public.albums set title = title where id = %L', v_a2_album), 0, 0),
      ('S2 owner 對非己相簿批次 update（a1）', 'a0000000-0000-4000-8000-000000000001',
       'update public.albums set title = title where title like ''ls412 plan %''', 1, 2),
      ('S2b owner 對孤兒相簿 by-id update（a1）', 'a0000000-0000-4000-8000-000000000001',
       format('update public.albums set title = title where id = %L', v_orphan_album), 1, 2)
    ) as t(label, uid, stmt, min_calls, max_calls)
  loop
    v_before := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0);
    perform set_config('request.jwt.claims',
      json_build_object('sub', q.uid, 'role', 'authenticated')::text, true);
    set local role authenticated;

    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    reset role;
    v_calls := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0) - v_before;

    if v_plan ~ '\(SubPlan [0-9]+\)' then
      raise exception E'FAIL 效能：% 的 plan 出現 per-row correlated SubPlan\n%', q.label, v_plan;
    end if;

    select coalesce(max((x[1])::bigint), 1) into v_loops
      from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
    if v_loops > 1 then
      raise exception E'FAIL 效能：% 的 plan 有節點被執行 % 次（孤兒集合遭逐列重算）\n%',
        q.label, v_loops, v_plan;
    end if;

    v_why := pg_temp.ls412_orphan_check(v_plan);
    if v_why <> '' then
      raise exception E'FAIL 效能：% —— %\n%', q.label, v_why, v_plan;
    end if;

    if v_calls > q.max_calls or v_calls < q.min_calls then
      raise exception E'FAIL 效能：% 孤兒集合函式被呼叫 % 次（預期 % 至 % 次；逐列呼叫會是相簿數量級）',
        q.label, v_calls, q.min_calls, q.max_calls;
    end if;

    raise notice 'ok 效能：% —— 無 correlated SubPlan、孤兒集合是 hashed SubPlan、所有節點 loops=1、集合函式呼叫 % 次', q.label, v_calls;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- S3：owner 實際呼叫 set_album_children（孤兒相簿、空陣列）——授權式跑一次集合（≤1、≥1）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_orphan_album uuid;
  v_before bigint;
  v_calls bigint;
begin
  select id into v_orphan_album from public.albums
   where title like 'ls412 plan %' and created_by is null limit 1;

  v_before := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_album_children(v_orphan_album, array[]::uuid[]);
  reset role;
  v_calls := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0) - v_before;

  if v_calls > 1 or v_calls < 1 then
    raise exception 'FAIL 效能：S3 set_album_children 的授權讓孤兒集合函式被呼叫 % 次（預期恰 1 次）', v_calls;
  end if;
  raise notice 'ok 效能：S3 set_album_children owner 呼叫 —— 孤兒集合函式呼叫 % 次', v_calls;
end;
$$;

-- ---------------------------------------------------------------------------
-- 偵測器自我驗證：owner 分支若對每列做 family_members 相關子查詢（內嵌 aggregate，
-- 規劃器無法拉平，PLAN §5 的必定逐列重算形狀，同 tests/50 自我驗證）必須被本檔判準抓到
-- （抓不到＝上面全部 ok 沒有意義）。注意規劃器會把單純 `EXISTS (相關子查詢)` 拉平成
-- join（實測：本機 PG 把它變成 Nested Loop、集合也只算一次），所以這裡用 count(*) 形狀。
-- ---------------------------------------------------------------------------
do $$
declare
  v_line text;
  v_plan text := '';
  v_loops bigint;
  v_bad_stmt text :=
    'select a.id from public.albums a
      where (select count(*) from public.family_members m
              where m.family_id = a.family_id
                and m.user_id = auth.uid() and m.role = ''owner'') > 0
        and (a.created_by is null
             or (select count(*) from public.family_members m2
                  where m2.family_id = a.family_id
                    and m2.user_id = a.created_by) = 0)
      limit 10000';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  for v_line in execute 'explain (analyze) ' || v_bad_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;

  if v_plan !~ '\(SubPlan [0-9]+\)' and v_loops <= 1 then
    raise exception E'FAIL：偵測器失效——逐列 correlated 子查詢竟然沒被判準抓到\n%', v_plan;
  end if;
  raise notice
    'ok 偵測器自我驗證：逐列 correlated 子查詢被抓到（correlated SubPlan=%，最大 loops=%）',
    (v_plan ~ '\(SubPlan [0-9]+\)'), v_loops;
end;
$$;

-- ---------------------------------------------------------------------------
-- 偵測器自我驗證 #2（LS-412 R2）：逐列函式包裝（M5）——新增 SECURITY DEFINER STABLE
-- `private.ls412_is_orphan(id)`（本體 `id in (select owned_orphan_album_ids())`），policy
-- owner 分支改 `or private.ls412_is_orphan(id)`。這是 R1 merge-review 用來騙過第一版判準的
-- 寫法：SD 函式不 inline，plan 沒有 `(SubPlan N)`、loops 全是 1（下面兩個 notice 會印出
-- 這件事），只有判準 3 抓得到。DDL 在本檔交易內，最後隨 rollback 消失。
-- ---------------------------------------------------------------------------
create function private.ls412_is_orphan(p uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select p in (select private.owned_orphan_album_ids()) $$;
revoke execute on function private.ls412_is_orphan(uuid) from public, anon;
grant execute on function private.ls412_is_orphan(uuid) to authenticated;

alter policy albums_update on public.albums
  using (
    (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
    or private.ls412_is_orphan(id)
  )
  with check (
    (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
    or private.ls412_is_orphan(id)
  );

do $$
declare
  v_line text;
  v_plan text := '';
  v_loops bigint;
  v_why text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;
  for v_line in execute 'explain (analyze, verbose, buffers)
      update public.albums set title = title where title like ''ls412 plan %''' loop
    v_plan := v_plan || v_line || E'\n';
  end loop;
  reset role;

  select coalesce(max((x[1])::bigint), 1) into v_loops
    from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
  raise notice 'M5 對照：correlated SubPlan=%，最大 loops=%（兩條舊判準對它看不見，符合預期）',
    (v_plan ~ '\(SubPlan [0-9]+\)'), v_loops;

  v_why := pg_temp.ls412_orphan_check(v_plan);
  if v_why = '' then
    raise exception E'FAIL：偵測器失效——逐列函式包裝（M5）竟然沒被判準 3 抓到\n%', v_plan;
  end if;
  raise notice 'ok 偵測器自我驗證 #2：逐列函式包裝（M5）被判準 3 抓到（%）', v_why;
end;
$$;

-- ---------------------------------------------------------------------------
-- 偵測器自我驗證 #3（LS-412 R3）：M6——保留 `id in (select owned_orphan_album_ids())` 的
-- hashed 集合，policy 另加 `or private.ls412_m6_wrap(id)` 逐列包裝。判準 1–3 對它全綠
-- （集合仍是 hashed SubPlan、無 correlated SubPlan、loops 全 1），只有判準 4 計數抓得到
-- （每列一次包裝呼叫→一次集合）。與 M5 negative control 分開命名，避免互相污染。
-- ---------------------------------------------------------------------------
create function private.ls412_m6_wrap(p uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select p in (select private.owned_orphan_album_ids()) $$;
revoke execute on function private.ls412_m6_wrap(uuid) from public, anon;
grant execute on function private.ls412_m6_wrap(uuid) to authenticated;

alter policy albums_update on public.albums
  using (
    (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
    or id in (select private.owned_orphan_album_ids())
    or private.ls412_m6_wrap(id)
  )
  with check (
    (created_by = (select auth.uid()) and family_id in (select private.contributor_family_ids()))
    or id in (select private.owned_orphan_album_ids())
    or private.ls412_m6_wrap(id)
  );

do $$
declare
  v_line text;
  v_plan text := '';
  v_before bigint;
  v_calls bigint;
  v_why text;
begin
  v_before := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;
  for v_line in execute 'explain (analyze, verbose, buffers)
      update public.albums set title = title where title like ''ls412 plan %''' loop
    v_plan := v_plan || v_line || E'\n';
  end loop;
  reset role;
  v_calls := coalesce(pg_stat_get_xact_function_calls('private.owned_orphan_album_ids()'::regprocedure), 0) - v_before;

  v_why := pg_temp.ls412_orphan_check(v_plan);
  raise notice 'M6 對照：判準 3 結果=%（空字串＝通過，符合預期：看不見 M6）；孤兒集合函式呼叫 % 次',
    coalesce(nullif(v_why, ''), '通過'), v_calls;

  if v_calls <= 2 then
    raise exception E'FAIL：偵測器失效——逐列包裝（M6）竟然沒被判準 4 計數抓到（呼叫 % 次）\n%', v_calls, v_plan;
  end if;
  raise notice 'ok 偵測器自我驗證 #3：逐列包裝（M6）被判準 4 抓到（孤兒集合函式呼叫 % 次，>2）', v_calls;
end;
$$;

rollback;
