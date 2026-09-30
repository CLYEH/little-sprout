-- LS-412：albums 孤兒集合的 plan-shape 常設 gate（LS-408 R1 i1／LS-409 R1 i3）
--
-- 背景：`albums_update` policy 的 owner 分支與 `set_album_children` 的授權都走
-- `id in (select private.owned_orphan_album_ids())`（LS-409）。這條寫法之所以安全，
-- 前提是規劃器把它收斂成 **hashed SubPlan、每個 statement 只算一次**；一旦被改成逐列
-- EXISTS／逐列函式呼叫，每列都會重算「owner 家庭內全部孤兒相簿」，成本變成
-- 相簿數的平方。LS-408 migration 註解宣稱這件事由 tests/50 的偵測機制覆蓋，但 tests/50
-- 沒有任何 albums 查詢——本檔補上，判準沿用 tests/50（loops 只能從 ANALYZE 取）：
--   1. plan 不得出現 `(SubPlan N)` 形式的 qual 引用（correlated、逐列）；
--   2. 所有節點 loops 必須是 1；
--   3. 額外要求 `hashed SubPlan` 真的出現（否則 1、2 在集合被拉平成別種 plan 時是恆真句）。
--
-- 為什麼是新檔而不是塞進 tests/50：tests/50 先灌 5 萬列 media＋2 萬列 storage.objects，
-- 本檔只需要 5000 列 albums，獨立跑快得多；判準與 tests/50 一字不差。
--
-- 三情境（票文範圍 1）：
--   S1 作者本人 update（a2，非 owner）：OR 的作者分支成立；孤兒集合對 a2 是空集合。
--   S2 owner 對非己相簿 update（a1）：走孤兒分支，USING 與 WITH CHECK 各建一次孤兒
--      id 雜湊表（LS-409 R1 i3：owner update 建集合兩次，成本與「家庭相簿數」成正比，
--      不隨列數放大；5000 列時各約 1 ms，本檔不改 policy，只把這件事記在這裡與 API.md §3）。
--   S3 `set_album_children` owner 呼叫：函式內是 plpgsql，EXPLAIN 看不進去，所以
--      (a) 斷言函式本體字面含 `p_album_id in (select private.owned_orphan_album_ids())`
--      （函式改寫成別種授權寫法就紅，不留「手抄副本與本體漂移」的洞，理由同 tests/50
--      get_family_timeline 段）；(b) 對「同一個」表達式做 EXPLAIN ANALYZE。
-- 另加 catalog 斷言：`private.owned_orphan_album_ids()` 必須是 STABLE。實測（本機 PG）
-- 把它改成 VOLATILE 時 plan 形狀不變（仍是 hashed SubPlan、loops=1），所以 plan 判準
-- 抓不到這個退步，只有這條 catalog 斷言抓得到——兩者分工，不是互為備援。
--
-- Mutation 自證（本票實跑，斷言原文見 PR 描述／handoff）：
--   M1 `private.owned_orphan_album_ids()` 改 VOLATILE（catalog 斷言紅）；
--   M2 albums_update 的 owner 分支改成逐列 count(*) 相關子查詢（plan 判準紅）；
--   M3 set_album_children 授權式改寫成別種形狀（S3(a) 字面斷言紅）。

\set ON_ERROR_STOP on

begin;

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
-- S3(a)：set_album_children 本體字面含孤兒集合授權式（正規化空白後比對）
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
begin
  select regexp_replace(pg_get_functiondef('public.set_album_children(uuid, uuid[])'::regprocedure),
                        '\s+', ' ', 'g') into v_def;
  if position('p_album_id in (select private.owned_orphan_album_ids())' in v_def) = 0 then
    raise exception E'FAIL 效能：set_album_children 授權不再是 `p_album_id in (select private.owned_orphan_album_ids())`——S3(b) 量的表達式與函式本體已不同，請同步本檔\n%', v_def;
  end if;
  raise notice 'ok S3(a)：set_album_children 授權式與本檔 S3(b) 量測的表達式一致';
end;
$$;

-- ---------------------------------------------------------------------------
-- plan 判準：四條 update（S1、S2 各 批次＋by-id 兩種形狀）＋S3(b) 授權表達式
-- ---------------------------------------------------------------------------
do $$
declare
  v_a2_album uuid;
  v_orphan_album uuid;
  q record;
  v_line text;
  v_plan text;
  v_loops bigint;
begin
  select id into v_a2_album from public.albums
   where title like 'ls412 plan %' and created_by = 'a0000000-0000-4000-8000-000000000002' limit 1;
  select id into v_orphan_album from public.albums
   where title like 'ls412 plan %' and created_by is null limit 1;

  for q in
    select * from (values
      ('S1 作者本人批次 update（a2）', 'a0000000-0000-4000-8000-000000000002',
       'update public.albums set title = title where title like ''ls412 plan %'''),
      ('S1b 作者本人 by-id update（a2，PostgREST 形狀）', 'a0000000-0000-4000-8000-000000000002',
       format('update public.albums set title = title where id = %L', v_a2_album)),
      ('S2 owner 對非己相簿批次 update（a1）', 'a0000000-0000-4000-8000-000000000001',
       'update public.albums set title = title where title like ''ls412 plan %'''),
      ('S2b owner 對孤兒相簿 by-id update（a1）', 'a0000000-0000-4000-8000-000000000001',
       format('update public.albums set title = title where id = %L', v_orphan_album)),
      ('S3(b) set_album_children owner 授權表達式（a1）', 'a0000000-0000-4000-8000-000000000001',
       format('select 1 where %L::uuid in (select private.owned_orphan_album_ids())', v_orphan_album))
    ) as t(label, uid, stmt)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', q.uid, 'role', 'authenticated')::text, true);
    set local role authenticated;

    v_plan := '';
    for v_line in execute 'explain (analyze, verbose, buffers) ' || q.stmt loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    reset role;

    if v_plan ~ '\(SubPlan [0-9]+\)' then
      raise exception E'FAIL 效能：% 的 plan 出現 per-row correlated SubPlan\n%', q.label, v_plan;
    end if;

    select coalesce(max((x[1])::bigint), 1) into v_loops
      from regexp_matches(v_plan, 'loops=([0-9]+)', 'g') as x;
    if v_loops > 1 then
      raise exception E'FAIL 效能：% 的 plan 有節點被執行 % 次（孤兒集合遭逐列重算）\n%',
        q.label, v_loops, v_plan;
    end if;

    if v_plan !~ 'hashed SubPlan' then
      raise exception E'FAIL 效能：% 的 plan 沒有 hashed SubPlan（孤兒集合不是單次求值的雜湊子計畫）\n%',
        q.label, v_plan;
    end if;

    raise notice 'ok 效能：% —— 無 correlated SubPlan、hashed SubPlan、所有節點 loops=1', q.label;
  end loop;
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

rollback;
