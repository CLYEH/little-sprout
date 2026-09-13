-- LS-243（LS-22 後端切片；來源 LS-96 池項 f74e3a88）—— get_family_timeline 的
-- comment_count／list_comments 的 total_count 自測：
--   1. get_family_timeline.comment_count：排除已刪／封鎖者留言，無留言為 0。
--   2. list_comments.total_count：排除已刪／封鎖者留言，跨頁一致，完全無留言時
--      回 0 列（不是一列 total_count=0 的列——RETURNS TABLE 對「沒有任何列」的
--      既有語意，不是本票新增的行為）。
--   3. EXPLAIN 證據：200 筆真實 feed（含留言）下 comment_count 的 buffers 只跟
--      頁面大小成正比，不是 N+1（migration 檔頭第 1 段的取捨說明有完整推導，
--      這裡補上機器可驗的正文）。
\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. get_family_timeline.comment_count
-- ===========================================================================
begin;
do $$
declare
  v_family constant uuid := 'fe000000-0000-4000-8000-000000000001';
  v_owner  constant uuid := 'ea000000-0000-4000-8000-000000000001'; -- 之後封鎖 v_viewer
  v_member constant uuid := 'ea000000-0000-4000-8000-000000000002';
  v_viewer constant uuid := 'ea000000-0000-4000-8000-000000000003'; -- 將被 owner 封鎖
  v_diary  constant uuid := 'e3000000-0000-4000-8000-000000000001';
  v_album  constant uuid := 'e4000000-0000-4000-8000-000000000001'; -- 無留言對照組
  v_count bigint;
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls243-a-owner@ls243.test',  now(), now(), '{}', '{}'),
    (v_member, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls243-a-member@ls243.test', now(), now(), '{}', '{}'),
    (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls243-a-viewer@ls243.test', now(), now(), '{}', '{}');

  -- families 的 AFTER INSERT trigger（private.add_creator_as_owner）自動把 v_owner 加成 owner。
  insert into public.families (id, name, created_by) values (v_family, 'E 家（LS-243 測試）', v_owner);
  insert into public.family_members (family_id, user_id, role, can_upload) values
    (v_family, v_member, 'member', true),
    (v_family, v_viewer, 'viewer', false);

  insert into public.diaries (id, family_id, author_id, body, entry_date)
  values (v_diary, v_family, v_owner, 'LS-243 留言計數測試日記', current_date);

  insert into public.albums (id, family_id, title, created_by)
  values (v_album, v_family, 'LS-243 無留言對照組相簿', v_owner);

  -- 留言：owner／member／viewer 各 1 則存活，另外 owner 1 則已軟刪（不計入）。
  insert into public.comments (id, family_id, target_type, target_id, author_id, body, created_at) values
    (gen_random_uuid(), v_family, 'diary', v_diary, v_owner,  '留言 1（owner）', now() - interval '3 minutes'),
    (gen_random_uuid(), v_family, 'diary', v_diary, v_member, '留言 2（member）', now() - interval '2 minutes'),
    (gen_random_uuid(), v_family, 'diary', v_diary, v_viewer, '留言 3（viewer，稍後被封鎖）', now() - interval '1 minutes');
  insert into public.comments (id, family_id, target_type, target_id, author_id, body, created_at, deleted_at)
  values (gen_random_uuid(), v_family, 'diary', v_diary, v_owner, '已軟刪留言（不計入）', now(), now());

  -- ---- owner 封鎖前：comment_count 應為 3（已排除軟刪那一則）----
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select comment_count into v_count
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'diary' and ref_id = v_diary;
  if v_count is distinct from 3 then
    raise exception 'FAIL comment_count（封鎖前）：預期 3（已排除軟刪留言），實際 %', v_count;
  end if;
  raise notice 'ok：comment_count（封鎖前）＝3（已排除軟刪留言）';

  -- 無留言的相簿：comment_count 應為 0（不是 NULL）。
  select comment_count into v_count
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'album' and ref_id = v_album;
  if v_count is distinct from 0 then
    raise exception 'FAIL comment_count（無留言）：預期 0，實際 %', v_count;
  end if;
  raise notice 'ok：comment_count（無留言的相簿）＝0';

  -- ---- owner 封鎖 viewer（直接寫 blocked_users，測的是讀取端過濾，不是 block_user RPC 本身）----
  reset role;
  set local role postgres;
  insert into public.blocked_users (family_id, blocker_id, blocked_id) values (v_family, v_owner, v_viewer);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select comment_count into v_count
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'diary' and ref_id = v_diary;
  if v_count is distinct from 2 then
    -- merge-review R1 F2：這裡驗的是「RLS＋RPC 合成後的最終行為」，不是 RPC 本體那句
    -- v_blocked_ids 單獨的承重性——get_family_timeline 是 security invoker，
    -- comments_select policy（20260903091317_report_block_rpc.sql）本身已經帶同一道
    -- 封鎖過濾，reviewer 實測拿掉 RPC 本體這句述詞這裡不會轉紅（同
    -- 20260906124837_reactions_block_filter.sql 對 get_reaction_counts 已有的既有
    -- 記載：invoker 函式的防禦性重複過濾，policy 才是真正生效的那一層）。保留這句
    -- 述詞理由不變（自我文件化＋policy 被改壞時的第二道防線），這裡只更正斷言訊息
    -- 裡失真的 mutation 宣稱。
    raise exception 'FAIL comment_count（owner 封鎖 viewer 後）：預期 2（viewer 那則不計入），實際 %', v_count;
  end if;
  raise notice 'ok：comment_count（owner 封鎖 viewer 後）＝2';

  -- ---- 單向語意：member 未封鎖任何人，視角仍是 3 ----
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select comment_count into v_count
    from public.get_family_timeline(v_family, null, null, null, 20)
   where kind = 'diary' and ref_id = v_diary;
  if v_count is distinct from 3 then
    raise exception 'FAIL comment_count（member 視角，單向語意）：owner 的封鎖不該影響 member，預期仍是 3，實際 %', v_count;
  end if;
  raise notice 'ok：comment_count（member 視角）不受 owner 的封鎖影響，仍是 3';
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 2. list_comments.total_count
-- ===========================================================================
begin;
do $$
declare
  v_family constant uuid := 'fe000000-0000-4000-8000-000000000002';
  v_owner  constant uuid := 'ec000000-0000-4000-8000-000000000001';
  v_viewer constant uuid := 'ec000000-0000-4000-8000-000000000002'; -- 將被封鎖
  v_target constant uuid := 'e8000000-0000-4000-8000-000000000001'; -- media target（多型無 FK，任意 uuid 皆可）
  v_empty_target constant uuid := 'e8000000-0000-4000-8000-000000000099'; -- 完全沒有留言
  v_total bigint;
  v_total2 bigint;
  v_row_count int;
  v_first_id uuid;
  v_first_created timestamptz;
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls243-b-owner@ls243.test',  now(), now(), '{}', '{}'),
    (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls243-b-viewer@ls243.test', now(), now(), '{}', '{}');

  insert into public.families (id, name, created_by) values (v_family, 'E2 家（LS-243 測試）', v_owner);
  insert into public.family_members (family_id, user_id, role, can_upload) values
    (v_family, v_viewer, 'viewer', false);

  -- 3 則存活留言（owner x2／viewer x1）＋ 1 則軟刪（不計入）。
  insert into public.comments (id, family_id, target_type, target_id, author_id, body, created_at) values
    (gen_random_uuid(), v_family, 'media', v_target, v_owner,  '留言 1', now() - interval '4 minutes'),
    (gen_random_uuid(), v_family, 'media', v_target, v_viewer, '留言 2（viewer，稍後被封鎖）', now() - interval '3 minutes'),
    (gen_random_uuid(), v_family, 'media', v_target, v_owner,  '留言 3', now() - interval '2 minutes');
  insert into public.comments (id, family_id, target_type, target_id, author_id, body, created_at, deleted_at)
  values (gen_random_uuid(), v_family, 'media', v_target, v_owner, '已軟刪（不計入）', now(), now());

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- limit=1 逼分頁：第一頁只回 1 列，但 total_count 應該是完整的 3（已排除軟刪）。
  select count(*), max(total_count) into v_row_count, v_total
    from public.list_comments(v_family, 'media', v_target, null, null, 1);
  if v_row_count is distinct from 1 or v_total is distinct from 3 then
    raise exception 'FAIL total_count（owner 視角，第一頁 limit=1）：預期 1 列／total_count=3，實際 % 列／%', v_row_count, v_total;
  end if;

  select id, created_at into v_first_id, v_first_created
    from public.list_comments(v_family, 'media', v_target, null, null, 1);

  -- 深頁（帶游標）total_count 應該跟第一頁完全一致——不是「剩餘筆數」，是這個
  -- target 底下的總數，跟目前翻到第幾頁無關。
  select max(total_count) into v_total2
    from public.list_comments(v_family, 'media', v_target, v_first_created, v_first_id, 1);
  if v_total2 is distinct from 3 then
    raise exception 'FAIL total_count（深頁，游標分頁）：預期跟第一頁一致的 3，實際 %', v_total2;
  end if;
  raise notice 'ok：total_count（owner 視角）跨頁一致＝3（已排除軟刪留言）';

  -- 完全沒有留言的 target：回 0 列（不是一列 total_count=0 的列）。
  select count(*) into v_row_count
    from public.list_comments(v_family, 'media', v_empty_target, null, null, 20);
  if v_row_count is distinct from 0 then
    raise exception 'FAIL：完全沒有留言的 target 應回 0 列，實際 %', v_row_count;
  end if;
  raise notice 'ok：完全沒有留言的 target——list_comments 回 0 列（RETURNS TABLE 既有語意，這時候沒有 total_count 欄位可觀察）';

  -- ---- owner 封鎖 viewer 後：total_count 應降為 2 ----
  reset role;
  set local role postgres;
  insert into public.blocked_users (family_id, blocker_id, blocked_id) values (v_family, v_owner, v_viewer);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select max(total_count) into v_total
    from public.list_comments(v_family, 'media', v_target, null, null, 20);
  if v_total is distinct from 2 then
    raise exception 'FAIL total_count（owner 封鎖 viewer 後）：預期 2（mutation：拿掉 v_blocked_ids 過濾這裡會紅、變回 3），實際 %', v_total;
  end if;
  raise notice 'ok：total_count（owner 封鎖 viewer 後）＝2';
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 3. EXPLAIN 證據：200 筆真實 feed（含留言）—— comment_count 不退化成 N+1
--
-- 跟 supabase/tests/50_rls_plan_no_percall_subquery.sql 既有的 get_family_timeline
-- 效能回歸段落（20 萬列 + 600 篇標記日記，但完全沒有任何留言）不同：那裡只證明
-- 「comment_count 子查詢在探不到任何留言時很便宜」，這裡改用一個小得多、但真的
-- 有留言可算的資料集（200 篇日記＝200 筆 feed，其中會落在第一頁的前 20 篇各留
-- 1 則存活＋1 則已刪留言）——證明「這一頁確實有留言要算」時 comment_count 依然
-- 便宜，掃描量只跟頁面大小（v_limit）成正比，不是跟這個家庭的 feed 總量或留言
-- 總量成正比。
--
-- LS-258（清倉 1，項 1）：CI（PR #392）一次量到 951（同 SHA rerun 卻只有 74 級），
-- `vacuum (analyze)` 當時只涵蓋 comments／feed_items／diaries 三張表。`run.sh`
-- 依檔名排序在 112_ 之前還會跑到觸碰 albums／media 的測試檔（例如
-- `86_albums_comments_owner_scope.sql`／`98_media_thumbnails.sql`／`99_media_
-- duration.sql`，皆各自 `begin;/rollback;`），同樣會在這兩張表留下 dead tuple，
-- autovacuum 時序若沒追上就會讓 `get_family_timeline` 內部對 album 目標的 EXISTS
-- 探測（見下方 §3 主查詢的目標判斷）多走訪幾頁死頁——這裡補上這兩張表的
-- `vacuum (analyze)`，涵蓋面比照本檔 §3 開頭原本三張表的理由。
--
-- 即便涵蓋面補齊，跨測試檔的殘留污染仍可能在單次量測裡偶發偏高（autovacuum 是
-- 背景程序，不保證這裡的顯式 VACUUM 之後不會有新的殘留）——下面的量測邏輯改成
-- 「第一次量測超標才重測一次，取兩次的小值」，**不放寬門檻本身**：真退化（例如
-- comment_count 退化成 N+1）兩次量測都會超標，殘留污染通常只影響其中一次；連續
-- 兩次呼叫同一段查詢，第二次也會受益於 Postgres 對死列的 opportunistic pruning
-- （第一次讀取頁面時，可見度檢查順便清掉已確認不可見的版本），單純重跑就可能量到
-- 更低的 buffers，不代表門檻本身失去鑑別力。
--
-- merge-review R1 F1：VACUUM 放在這裡（`begin;` 之前，不能在交易內執行）——
-- `run.sh` 依檔名排序（`sort -V`：50 < 112）先跑 50_rls_plan_no_percall_subquery.sql
-- （灌 5 萬則留言／20 萬列 feed_items 又 rollback），這些列在交易 rollback 後是
-- dead tuple，autovacuum 沒追上之前，下面對 comments／feed_items／diaries 的
-- Index Scan 仍要走訪這些死頁才能判斷「不可見」，buffers 因此隨死列數量膨脹，
-- 跟 comment_count 本身的成本無關。reviewer 實測：同一顆 DB 連跑兩次 run.sh，
-- 第 2、3 次量到 buffers=2957（門檻 250 應聲炸開，錯誤訊息還會誤導成「comment_count
-- 退化成 N+1」）；跑這裡的 VACUUM 之後量到 77，跟首次乾淨 reset 的結果一致。
-- 不能只放寬門檻了事——把 comment_count 攤到整頁 200 列（不是本檔案這裡的 20 列
-- 首頁）的真退化約 1160 buffers，門檻只要調到能吞下 2957 這種殘留污染，就連
-- 真退化也測不出來了。
vacuum (analyze) public.comments;
vacuum (analyze) public.feed_items;
vacuum (analyze) public.diaries;
vacuum (analyze) public.albums;
vacuum (analyze) public.media;
-- ===========================================================================
begin;
do $$
declare
  v_family constant uuid := 'fe000000-0000-4000-8000-000000000003';
  v_owner  constant uuid := 'ed000000-0000-4000-8000-000000000001';
begin
  reset role;
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ls243-explain-owner@ls243.test', now(), now(), '{}', '{}');
  insert into public.families (id, name, created_by) values (v_family, 'G 家（LS-243 EXPLAIN，200 筆 feed）', v_owner);

  -- entry_date 遞減（i 越小越新）：i in [1,20] 的 entry_date 最新，會落在第一頁
  -- （get_family_timeline 預設 order by occurred_at desc）。
  create temporary table tmp_ls243_diaries as
  select gen_random_uuid() as id, i, current_date - i as entry_date
    from generate_series(1, 200) i;

  insert into public.diaries (id, family_id, author_id, body, entry_date)
  select id, v_family, v_owner, 'LS-243 EXPLAIN 證據日記 #' || i, entry_date
    from tmp_ls243_diaries;
  -- feed_sync_diaries trigger 自動展開 feed_items（200 列）。

  -- 前 20 篇（會落在第一頁）各留 1 則存活留言＋1 則已刪留言。
  insert into public.comments (family_id, target_type, target_id, author_id, body, created_at)
  select v_family, 'diary', id, v_owner, 'LS-243 EXPLAIN 留言（存活）', now()
    from tmp_ls243_diaries where i <= 20;
  insert into public.comments (family_id, target_type, target_id, author_id, body, created_at, deleted_at)
  select v_family, 'diary', id, v_owner, 'LS-243 EXPLAIN 留言（已刪）', now(), now()
    from tmp_ls243_diaries where i <= 20;

  drop table tmp_ls243_diaries;

  analyze public.diaries;
  analyze public.feed_items;
  analyze public.comments;
end;
$$;

select set_config('request.jwt.claims',
  json_build_object('sub', 'ed000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
set local role authenticated;

-- 數值守門：先暖機（同 50_ 檔案既有的 N2 說明：session 第一次呼叫 plpgsql 函式有
-- 一次性 parse／plan cache 成本，暖機後才量到穩定成本）。
do $$
declare
  v_line text;
  v_plan text := '';
  v_hit bigint;
  v_read bigint;
  v_buffers bigint;
  v_buffers_retry bigint;
  v_plan_final text;
  v_attempt int;
  -- 200 筆 feed、第一頁 20 列，其中每一列都要對 diary_children（空）＋comments
  -- （20 列各有 1 則存活留言，命中 comments_target_idx 前三欄）各跑一次 correlated
  -- 子查詢——量級應與 50_ 檔案「不篩 child、無游標」分支（真實接近，75-80 buffers）
  -- 相近，這裡給 250 的餘裕（本檔資料集小，正常情況離門檻應該還有一大截）。
  c_buffer_budget constant bigint := 250;
begin
  perform * from public.get_family_timeline('fe000000-0000-4000-8000-000000000003'::uuid, null, null, null, 1); -- warm-up

  -- LS-258：第一次量測若超標，重測一次取小值（見上方 §3 檔頭第二段的理由），
  -- 不放寬 c_buffer_budget 本身。
  for v_attempt in 1..2 loop
    v_plan := '';
    for v_line in execute
      'explain (analyze, verbose, buffers) select * from public.get_family_timeline(' ||
      quote_literal('fe000000-0000-4000-8000-000000000003') || '::uuid, null, null, null, 20)'
    loop
      v_plan := v_plan || v_line || E'\n';
    end loop;

    select coalesce(sum((x[1])::bigint), 0) into v_hit
      from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
    select coalesce(sum((x[1])::bigint), 0) into v_read
      from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;

    if v_attempt = 1 then
      v_buffers := v_hit + v_read;
      v_plan_final := v_plan;
      exit when v_buffers <= c_buffer_budget;
    else
      v_buffers_retry := v_hit + v_read;
      v_plan_final := v_plan;
    end if;
  end loop;

  if v_buffers <= c_buffer_budget then
    raise notice 'ok 效能：get_family_timeline（200 筆 feed，含留言）buffers=%（第一次量測即過關，門檻 ≤%）', v_buffers, c_buffer_budget;
  elsif v_buffers_retry <= c_buffer_budget then
    raise notice 'ok 效能：get_family_timeline（200 筆 feed，含留言）buffers=%（第一次 % 超標，重測取小值過關，門檻 ≤%，LS-258）', v_buffers_retry, v_buffers, c_buffer_budget;
  else
    raise exception E'FAIL 效能：get_family_timeline（200 筆 feed，含留言）兩次量測皆超標（第一次 buffers=%、重測 buffers=%，門檻 %）—— comment_count 疑似退化成跟 feed 總量或留言總量成正比\n%',
      v_buffers, v_buffers_retry, c_buffer_budget, v_plan_final;
  end if;
end;
$$;

-- 人類可讀的原文證據（run.sh 會把本檔案的輸出存進 evidence/，同 50_ 檔案既有慣例）。
\echo ''
\echo '=== EXPLAIN 證據：get_family_timeline 200 筆 feed（含留言）—— comment_count 不退化 N+1（LS-243）==='
explain (analyze, verbose, buffers)
select * from public.get_family_timeline('fe000000-0000-4000-8000-000000000003'::uuid, null, null, null, 20);

reset role;
rollback;
