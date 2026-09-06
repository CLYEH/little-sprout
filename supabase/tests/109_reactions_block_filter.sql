-- LS-225（LS-23 後端切片）——LS-149 封鎖過濾漏了 reactions，本檔驗證
-- get_reaction_counts()／reactions_select 補上的 blocked_pairs 述詞。
--
-- 不借用 00_fixtures.sql 的 A／B 家：A 家 owner a1 已經封鎖 A 家 viewer a3（fixture
-- 既有關係，100_report_block_rpc.sql 依賴它），若沿用會讓「封鎖前 A 視角應看到 2」
-- 這個前提條件在測試一開始就不成立。改建一個測試專用的 D 家（fd...），三個全新
-- 成員（A=owner／B=member／C=viewer，跟既有家庭的角色慣例一致），全部包在
-- `begin ... rollback` 交易內（postgres 身分直接寫，繞過 RLS，同其他測試檔既有
-- fixture 準備慣例），交易結束不留殘料。
--
-- target_id 沒有 FK（多型關聯，見 docs/API.md §3「comments／reactions」段），可以
-- 用任意 uuid，不需要真的建一筆 media。
\set ON_ERROR_STOP on

begin;

-- ===========================================================================
-- 1. 主情境：A／B／C 同家庭，B／C 各按讚一則 → A 封鎖 B → A 解除封鎖
-- ===========================================================================
do $$
declare
  v_family constant uuid := 'fd000000-0000-4000-8000-000000000001';
  v_a      constant uuid := 'd0000000-0000-4000-8000-000000000001'; -- A：owner（封鎖者）
  v_b      constant uuid := 'd0000000-0000-4000-8000-000000000002'; -- B：member（將被封鎖）
  v_c      constant uuid := 'd0000000-0000-4000-8000-000000000003'; -- C：viewer
  v_target constant uuid := '9d000000-0000-4000-8000-000000000001';
  v_n int;
  v_reacted boolean;
  v_user_ids uuid[];
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls225-a@ls225.test', now(), now(), '{}', '{}'),
    (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls225-b@ls225.test', now(), now(), '{}', '{}'),
    (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls225-c@ls225.test', now(), now(), '{}', '{}');

  -- families 的 AFTER INSERT trigger（private.add_creator_as_owner）自動把 v_a 加成 owner。
  insert into public.families (id, name, created_by) values (v_family, 'D 家（LS-225 測試）', v_a);
  insert into public.family_members (family_id, user_id, role, can_upload) values
    (v_family, v_b, 'member', true),
    (v_family, v_c, 'viewer', false);

  -- B、C 各按讚一則。
  insert into public.reactions (family_id, target_type, target_id, user_id) values
    (v_family, 'media', v_target, v_b),
    (v_family, 'media', v_target, v_c);

  -- ---- 封鎖前基準：A 視角計數 2、名單含 B／C、reacted_by_me=false（A 沒按讚）----
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select reaction_count, reacted_by_me into v_n, v_reacted
    from public.get_reaction_counts(v_family, 'media', array[v_target]);
  if v_n is distinct from 2 or v_reacted is distinct from false then
    raise exception 'FAIL 封鎖前基準（get_reaction_counts）：預期 count=2／reacted_by_me=false，實際 count=%／reacted_by_me=%', v_n, v_reacted;
  end if;

  select array_agg(user_id order by user_id) into v_user_ids
    from public.reactions where family_id = v_family and target_id = v_target;
  if v_user_ids is distinct from (select array_agg(u order by u) from unnest(array[v_b, v_c]) u) then
    raise exception 'FAIL 封鎖前基準（reactions_select 名單）：預期 B／C 皆在，實際 %', v_user_ids;
  end if;

  raise notice 'ok：封鎖前基準——A 視角計數 2、名單含 B／C、reacted_by_me=false';

  -- ---- A 封鎖 B（直接寫 blocked_users，測的是讀取端述詞，不是 block_user RPC 本身）----
  reset role;
  set local role postgres;
  insert into public.blocked_users (family_id, blocker_id, blocked_id) values (v_family, v_a, v_b);

  -- ---- 封鎖後：A 視角計數 1、名單只剩 C、reacted_by_me 不受影響（仍 false）----
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select reaction_count, reacted_by_me into v_n, v_reacted
    from public.get_reaction_counts(v_family, 'media', array[v_target]);
  if v_n is distinct from 1 or v_reacted is distinct from false then
    raise exception 'FAIL 封鎖後（get_reaction_counts）：A 封鎖 B 後預期 count=1／reacted_by_me=false（mutation：拿掉 RPC 的 NOT EXISTS 這裡會紅，count 會變回 2），實際 count=%／reacted_by_me=%', v_n, v_reacted;
  end if;

  select array_agg(user_id order by user_id) into v_user_ids
    from public.reactions where family_id = v_family and target_id = v_target;
  if v_user_ids is distinct from array[v_c] then
    raise exception 'FAIL 封鎖後（reactions_select 名單）：A 封鎖 B 後名單應只剩 C（mutation：拿掉 reactions_select 的 NOT EXISTS 這裡會紅，B 仍在名單），實際 %', v_user_ids;
  end if;

  raise notice 'ok：封鎖後——A 視角計數 1、名單只剩 C、reacted_by_me 不受影響';

  -- ---- B 視角（單向）：B 自己看仍是 2——A 的封鎖不影響 B 看自己家庭的反應 ----
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select reaction_count into v_n
    from public.get_reaction_counts(v_family, 'media', array[v_target]);
  if v_n is distinct from 2 then
    raise exception 'FAIL 單向語意（B 視角／get_reaction_counts）：B 未封鎖任何人，預期仍看到 count=2，實際 %', v_n;
  end if;

  select count(*) into v_n from public.reactions where family_id = v_family and target_id = v_target;
  if v_n <> 2 then
    raise exception 'FAIL 單向語意（B 視角／reactions_select）：預期 2 筆，實際 %', v_n;
  end if;

  raise notice 'ok：單向語意——B 視角不受 A 的封鎖影響，仍看到計數 2';

  -- ---- 跨家庭隔離：A 對 B 的封鎖只登記在 D 家（family_id=fd），臨時把 A／B 加進
  -- B 家（fb，00_fixtures.sql 既有家庭）當 viewer，B 在 fb 按讚一則既有 fixture
  -- target；A 查 fb 的計數不該被 D 家的封鎖關係濾掉——用來驗證 blocked_pairs 的
  -- NOT EXISTS 有正確用 family_id 限定，不是只比對 blocked_id（若漏了 family_id
  -- 限定，這裡會被錯誤濾掉，跟下面斷言的「仍看到 2」矛盾）----
  reset role;
  set local role postgres;
  insert into public.family_members (family_id, user_id, role, can_upload) values
    ('fb000000-0000-4000-8000-000000000001', v_a, 'viewer', false),
    ('fb000000-0000-4000-8000-000000000001', v_b, 'viewer', false);
  insert into public.reactions (family_id, target_type, target_id, user_id) values
    ('fb000000-0000-4000-8000-000000000001', 'media', '3b000000-0000-4000-8000-000000000001', v_b);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select reaction_count into v_n
    from public.get_reaction_counts(
      'fb000000-0000-4000-8000-000000000001', 'media',
      array['3b000000-0000-4000-8000-000000000001'::uuid]
    );
  -- fb 既有 fixture 反應（b2，7b000000...001）＋這裡新增的 B（v_b）＝2。
  if v_n is distinct from 2 then
    raise exception 'FAIL 跨家庭隔離：A 對 B 的封鎖只登記在 D 家，B 家（fb）應不受影響、預期 count=2，實際 %（疑似 blocked_pairs 的 NOT EXISTS 漏了 family_id 限定）', v_n;
  end if;

  raise notice 'ok：跨家庭隔離——D 家的封鎖關係不影響 B 家（fb）的計數';

  -- ---- A 解除封鎖：D 家計數恢復 2 ----
  reset role;
  set local role postgres;
  delete from public.blocked_users where family_id = v_family and blocker_id = v_a and blocked_id = v_b;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select reaction_count into v_n
    from public.get_reaction_counts(v_family, 'media', array[v_target]);
  if v_n is distinct from 2 then
    raise exception 'FAIL 解除封鎖：預期恢復 count=2，實際 %', v_n;
  end if;

  raise notice 'ok：解除封鎖——D 家計數恢復 2';
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 2. 效能證據：對真正的 RPC 呼叫量測，不手抄函式本體副本
--
-- merge-review R1 M1（LS-225 R2 修正）：原本這裡把 get_reaction_counts 的函式本體
-- SQL 抄一份成 v_stmt、EXPLAIN 的是這份副本，不是 RPC 本身——reviewer 實測拿掉
-- migration 函式本體的 `and r.target_id = any (p_target_ids)` 後，這裡連同其餘三個
-- 測試檔全部維持全綠，但真實 RPC 已經退化成掃整個家庭的 reactions（同一份 5000
-- 筆反應／250 target 資料集：rows 20→251、shared hit 1075→5289）。這正是本 repo
-- 已經裁決過一次要根除的模式（見 50_rls_plan_no_percall_subquery.sql:358-381，
-- LS-121 R2 N1：「拿掉手抄 SQL 副本探針，一律透過真正呼叫函式本身來量測…從根本上
-- 排除副本與本體不同步這個問題類別」）。
--
-- 改法（兩條斷言，對應 R1 M1 建議的 (a)＋(b)）：
--   (a) 對真正的 RPC 呼叫（不是副本）`explain (analyze, buffers)`，斷言 buffers
--       低於門檻——這支函式帶 `set search_path = ''`，Postgres inline 條件排除有
--       SET 子句的函式（不分 invoker／definer），EXPLAIN 對呼叫本身只看得到不透明
--       的 `Function Scan on get_reaction_counts` 節點、看不進內層 Index Cond 字面
--       （跟 get_family_timeline 當初接受的取捨一樣，見 50_ 同一段落 N1 說明）；
--       但 buffers 會穿透這層不透明——reviewer 已實測退化與正常兩種情況的數量級
--       差距（1075 vs 5289），buffers 判別力足夠。
--   (b) `pg_get_functiondef()` 結構性斷言：函式本體原文必須同時含
--       `target_id = any(p_target_ids)` 與 `blocked_pairs`——純文字檢查，不依賴
--       資料量或 planner 選擇，跟 (a) 互補（(a) 抓「掃描量變大」這一種退化；(b) 抓
--       「函式本體被改寫但巧合維持住相近 buffers」這種理論上可能、但 (a) 抓不到的
--       drift）。
--
-- 資料量沿用 50_rls_plan_no_percall_subquery.sql 既有 get_reaction_counts 效能段落
-- 同一組量級（250 個 target、20 個反應者、5000 筆反應），另建專屬 F 家不干擾其他
-- 測試檔的資料。額外加一筆 blocked_users，讓 blocked_pairs 的 NOT EXISTS 不是空
-- 探查（0 筆封鎖時規劃器可能選擇不同的 plan 形狀）。
-- ===========================================================================
begin;
do $$
declare
  v_family constant uuid := 'ff000000-0000-4000-8000-000000000001';
  v_owner  constant uuid := 'f1000000-0000-4000-8000-000000000001';
  v_targets uuid[];
  v_n bigint;
  v_line text;
  v_plan text := '';
  v_stmt text;
  v_hit bigint;
  v_read bigint;
  v_buffers bigint;
  v_funcdef text;
  -- reviewer 實測正常 1075、退化（拿掉 target_id 篩選）5289；門檻取中間值，兩邊都
  -- 留有數量級內的餘裕（正常側餘裕 ~1.9x、退化側超標 ~2.6x）。
  c_buffer_budget constant bigint := 2500;
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ls225-explain-owner@ls225.test', now(), now(), '{}', '{}');
  insert into public.families (id, name, created_by) values (v_family, 'F 家（LS-225 EXPLAIN）', v_owner);

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  select ('f2000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
         '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'ls225-explain-reactor-' || i || '@ls225.test', now(), now(), '{}', '{}'
    from generate_series(1, 20) i;

  select array_agg(('f4000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid)
    into v_targets
    from generate_series(1, 250) i;

  insert into public.reactions (family_id, target_type, target_id, user_id)
  select v_family, 'media', t, u
    from unnest(v_targets) as t
   cross join lateral (
     select ('f2000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as u
       from generate_series(1, 20) i
   ) users;
  analyze public.reactions;

  select count(*) into v_n from public.reactions where family_id = v_family;
  if v_n < 5000 then
    raise exception 'FAIL：EXPLAIN 證據需要 ≥5000 筆反應，實際只有 %', v_n;
  end if;

  -- owner 封鎖反應者 #1（f2...0001），讓 blocked_pairs 的 NOT EXISTS 真的有一筆要濾。
  insert into public.blocked_users (family_id, blocker_id, blocked_id)
  values (v_family, v_owner, 'f2000000-0000-4000-8000-000000000001');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 正確性：20 個反應者裡有 1 個被封鎖，任一 target 的計數應為 19。
  select reaction_count into v_n
    from public.get_reaction_counts(v_family, 'media', array[v_targets[1]]);
  if v_n is distinct from 19 then
    raise exception 'FAIL：EXPLAIN 證據資料集下 get_reaction_counts 應濾掉被封鎖者、回傳 19，實際 %', v_n;
  end if;

  -- (a) 對真正的 RPC 呼叫量 buffers（不是副本）——mutation：拿掉 migration 函式
  -- 本體的 `and r.target_id = any (p_target_ids)` 會讓這裡的 buffers 從 ~1075
  -- 跳到 ~5289，超過門檻變紅。
  v_stmt := format(
    'select * from public.get_reaction_counts(%L::uuid, %L, %L::uuid[])',
    v_family, 'media', v_targets[1:20]
  );
  for v_line in execute 'explain (analyze, buffers) ' || v_stmt loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  select coalesce(sum((x[1])::bigint), 0) into v_hit
    from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
  select coalesce(sum((x[1])::bigint), 0) into v_read
    from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;
  v_buffers := v_hit + v_read;

  if v_buffers > c_buffer_budget then
    raise exception E'FAIL 效能：get_reaction_counts（真 RPC，非副本）buffers=%（hit=% read=%，門檻 %）—— 疑似 target_id 篩選遺失，掃描量與整個家庭的反應數成正比而不是與查詢帶的 20 個 target 成正比\n%',
      v_buffers, v_hit, v_read, c_buffer_budget, v_plan;
  end if;

  raise notice 'ok 效能：get_reaction_counts（真 RPC，非副本）—— buffers=%（hit=% read=%，門檻 %）', v_buffers, v_hit, v_read, c_buffer_budget;

  -- (b) 結構性斷言：函式本體原文必須同時含 target_id 篩選與 blocked_pairs 述詞。
  select pg_get_functiondef(p.oid) into v_funcdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reaction_counts';

  if v_funcdef !~ 'target_id\s*=\s*any\s*\(\s*p_target_ids\s*\)' then
    raise exception E'FAIL 結構：get_reaction_counts 函式本體遺失 target_id = any(p_target_ids) 篩選\n%', v_funcdef;
  end if;
  if v_funcdef !~ 'blocked_pairs' then
    raise exception E'FAIL 結構：get_reaction_counts 函式本體遺失 blocked_pairs 封鎖過濾\n%', v_funcdef;
  end if;

  raise notice 'ok 結構：get_reaction_counts 函式本體同時含 target_id = any(p_target_ids) 與 blocked_pairs';
end;
$$;
reset role;
rollback;
