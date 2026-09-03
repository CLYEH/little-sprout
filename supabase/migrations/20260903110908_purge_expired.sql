-- LS-153 — 軟刪與刪除帳號後 30 天自動永久清除排程
--
-- 背景（票文）：docs/API.md:1263 一直明文「media 軟刪不硬刪 Storage」；children 的
-- 30 天可還原窗口（LS-66，set_child_deleted 的 LS043）與 delete_my_account()
-- （LS-143，profiles.deletion_requested_at）都留了一句「超過 30 天後的清除策略留給
-- 排程票」。這票把那句話兌現：LS-132 隱私政策要能承諾「系統於 30 天內自動永久清除」，
-- 不是「人工」。
--
-- 範圍（票文 1-5，本 migration 只做「資料面＋排程」，Storage 物件的實際刪除由
-- supabase/functions/purge-storage 這支 Edge Function 消化本檔建立的佇列表）：
--   1. private.purge_expired(p_now)：diaries／albums／comments／media／children／
--      profiles 六張表，各自的 deleted_at／deletion_requested_at 超過 30 天前 → 硬刪。
--   2. media 硬刪前先把 storage_path／thumb_path 收進 public.purge_storage_queue，
--      交給 Edge Function 之後刪除實體物件（此表是 service_role-only，同
--      notification_events 的既有模式）。
--   3. private.purge_runs：每次執行留一列（時間、各表筆數、Storage 佇列筆數、失敗數）。
--   4. pg_cron 每日排程（fail-soft：本機開發映像若沒有 shared_preload_libraries 載入
--      pg_cron，CREATE EXTENSION 會直接噴錯，這裡整段吞掉、只留 NOTICE，不擋
--      migration chain——ticket 明文要求）。
--
-- 規格分歧與取捨（票文要求列出，供之後改動的人對照；handoff 已同步）：
--
--   a) 「家庭整體（LS-143 情況 2）同規則」——已在事實上被 LS-143 滿足，這裡沒有新增
--      任何邏輯：LS-143 情況 2（呼叫者是某家庭唯一成員）在 delete_my_account() 呼叫
--      的**當下**就用 `DELETE FROM public.families` cascade 整個刪掉，不是先軟刪、
--      等 30 天再清——families 這張表從來沒有 deleted_at 欄位（
--      20260822120000_init_schema.sql，通篇沒有），也就沒有「等 30 天」這個狀態可
--      以存在。本 migration 因此不對 families 做任何事；「同規則」在這裡的意思是
--      「情況 2 的清除時間點（立即）比這票的 30 天窗口更嚴格，不需要也不應該放寬」，
--      不是「families 也要新增一個 30 天欄位」。
--
--   b) profiles 是否該在 30 天後硬刪，即使 Edge Function delete-account（LS-151，
--      本票開票時仍是 Backlog、尚未實作）還沒有把 auth.users 一併刪掉——**採最保守
--      解：刪**。理由：
--        - LS-151 的職責是「立即」在 delete_my_account() 回傳後刪 auth.users
--          （docs/API.md §4 明文的 client 契約），正常路徑下 profiles 活不到 30 天；
--          這裡的 30 天硬刪是那條路徑失敗時（client crash、網路斷線、Edge Function
--          本身出錯）的最後防線——隱私政策的承諾是「使用者資料 30 天內清除」，不是
--          「auth.users 30 天內清除」，profiles 裡的 display_name／avatar_url 正是
--          使用者資料，不該因為另一支流程失敗就無限期留著。
--        - profiles.id 對 auth.users 是 `on delete cascade`（單向：auth.users 沒了
--          profiles 才跟著沒，反過來不成立），刪 profiles 不會、也不能連帶刪掉
--          auth.users——這裡故意留下的技術後果是「auth.users 列還在、但沒有對應
--          profiles」的孤兒帳號：這個人理論上還能用 Apple/Google 登入，但
--          20260826005443_profiles_auto_create_trigger.sql 的自動建立 trigger 只掛
--          在 auth.users 的 **INSERT**（不是每次登入都觸發），既有帳號重新登入不會
--          自動補回 profiles——app 端幾乎所有 RPC／RLS policy 都預期 profiles 存在，
--          這個孤兒帳號實務上會馬上撞到一連串失敗，等同被鎖住，不是「悄悄留著能用」。
--        - 這是本票能做到、且不越權去動 auth.users（票文「不做」段，LS-151 的範圍）
--          的前提下最安全的選擇：資料如實刪除，副作用是一個功能性鎖死、需要 LS-151
--          最終完成才能徹底收尾的孤兒帳號，而不是讓使用者資料違背 30 天承諾。
--          orchestrator／LS-151 落地後應該補一條巡檢：auth.users 存在但找不到對應
--          profiles 且建立超過（例如）31 天的列，代表 LS-151 那支 Edge Function
--          當時失敗過，需要人工跑一次補償刪除——這不是本票能做的事（本票不碰
--          auth.users），留在 handoff 供 orchestrator 判斷是否另開票。
--
--   c) 執行機制擇一：選 (a) pg_cron 呼叫 private.purge_expired()＋獨立 Edge Function
--      消化 Storage 佇列，不選「單一排程 Edge Function 兩件事都做」。理由：
--        - DB 端的清除邏輯（六張表的 WHERE 條件、失敗重試、與 restore_child／upload
--          的併發正確性）能且應該用 supabase/tests 的既有 SQL 測試機制驗證——這是
--          本 repo 目前唯一「本機可重複驗證」的測試路徑；把它包進 Deno Edge Function
--          會讓這些正確性只能在部署後才測得到。
--        - Storage 物件的實際刪除需要呼叫 Storage Admin API（不是純 SQL 能做的事），
--          必須是 Edge Function 或某種外部程式；但那部分的邏輯很薄（讀佇列、呼叫
--          API、刪掉處理完的列），沒有理由連帶把「六張表的刪除規則」也一起搬過去、
--          放棄掉 SQL 測試的覆蓋。
--      **本票如實揭露一個已知限制**：`supabase/functions/purge-storage`
--      （Edge Function 本體）在這個 migration 之外另外新增，本機沒有可用的 Deno
--      Edge Runtime 整合測試環境（`supabase functions serve` 需要的容器在這個開發
--      環境沒有跑過、也沒有時間建置驗證），因此那支函式**沒有**經過任何自動化測試，
--      只有人工 code review 等級的把關——這點在 PR body／handoff 裡如實寫明，不假裝
--      「已驗證」。真正會被物理刪除的 Storage 物件路徑清單本身（`purge_storage_queue`
--      這張表的內容）則完全由本 migration 的 SQL 測試覆蓋（29/31 天、跨家庭隔離、
--      冪等重跑），可信度與其他六張表相同；缺的只是「佇列建好之後，Edge Function
--      真的把它消化掉」這一段。
--
--   d) 執行時機：pg_cron 每日一次（`0 19 * * *`，UTC 19:00 ≈ 台北時間凌晨 3 點，
--      低流量時段），不是即時觸發（票文「不做」段：即時清除不在範圍）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 0. 效能索引：六張表現有的 partial index 都只覆蓋「未刪除」的列（服務一般查詢），
--    purge_expired() 反過來要掃「已刪除、且超過 30 天」的列，沒有對應索引會是全表掃描
--    ——family 一多，diaries/albums/comments/media 都可能到百萬列量級（見
--    50_rls_plan_no_percall_subquery.sql 的效能 fixture：單一家庭就放了 5 萬列
--    media）。四張表 deleted_at、profiles 一張 deletion_requested_at，皆為
--    partial index（只索引非 NULL，符合這兩欄「多數列是 NULL」的實際分佈）。
-- ---------------------------------------------------------------------------
create index diaries_deleted_at_idx on public.diaries (deleted_at) where deleted_at is not null;
create index albums_deleted_at_idx on public.albums (deleted_at) where deleted_at is not null;
create index comments_deleted_at_idx on public.comments (deleted_at) where deleted_at is not null;
create index media_deleted_at_idx on public.media (deleted_at) where deleted_at is not null;
create index children_deleted_at_idx on public.children (deleted_at) where deleted_at is not null;
create index profiles_deletion_requested_idx
  on public.profiles (deletion_requested_at) where deletion_requested_at is not null;

-- ---------------------------------------------------------------------------
-- 1. private.purge_runs —— 觀測用，供 orchestrator 巡檢（mcp__supabase__execute_sql
--    直接查，不經 PostgREST；private schema 未被 supabase/config.toml 的 [api] 曝露，
--    這張表天生沒有 REST endpoint，見 storage_policies.sql／rls_policies.sql 對
--    private schema 曝露範圍的既有說明）。
--
-- 為什麼放 private 不放 public：這張表沒有任何呼叫端需要透過 PostgREST 存取（Edge
-- Function 讀的是下面的 purge_storage_queue，不是這張），放 private 不必逐一登記進
-- docs/API.md §9 的 API-CONTRACT:TABLES（那份清單只管 public schema 的可呼叫表面），
-- 也不必為它另外考慮 RLS policy 設計——private schema 的表對 authenticated 天生零
-- table grant（schema USAGE 只解決「看得到物件名字」，不含任何 DML 權限；Supabase
-- 專案佈建把 anon/authenticated 全開的 default ACL 只灌進 public schema，
-- 20260822120000_init_schema.sql 那句 `revoke all on tables from anon, authenticated`
-- 特別標注 `in schema public` 正是因為只有那裡需要收），比照 notification_events
-- 的「兩層防線」style 仍然明確 enable RLS＋不建立任何 policy，不依賴這份分析當唯一
-- 防線。
-- ---------------------------------------------------------------------------
create table private.purge_runs (
  id uuid primary key default gen_random_uuid(),
  run_at timestamptz not null default now(),
  p_now timestamptz not null,
  deleted_counts jsonb not null,
  storage_enqueued integer not null default 0 check (storage_enqueued >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  failures jsonb not null default '[]'::jsonb
);

comment on table private.purge_runs is
  'private.purge_expired() 每次執行留一列觀測紀錄（LS-153）：p_now 是那次呼叫實際'
  ' 用的截止基準（測試會注入固定值，正式排程用預設的 now()）；deleted_counts 是'
  ' {"diaries":n,"albums":n,...} 六張表各自的硬刪筆數；failed_count／failures 記錄'
  ' 個別表格清除失敗的次數與原因（每張表獨立 exception 區塊，一張表失敗不影響其他'
  ' 表照常清除，見 purge_expired() 函式本體）。orchestrator 巡檢用'
  ' mcp__supabase__execute_sql 直接查，這張表不經 PostgREST（private schema 未被'
  ' [api] 曝露）。';

alter table private.purge_runs enable row level security;
-- 刻意不建立任何 policy（比照 notification_events 的兩層防線 style）；本表只有
-- private.purge_expired() 以 SECURITY DEFINER／表擁有者身分寫入，讀取交給
-- orchestrator 的 service_role 連線（mcp__supabase__execute_sql 走管理端連線，不受
-- RLS／PostgREST grant 影響）。

-- ---------------------------------------------------------------------------
-- 2. public.purge_storage_queue —— Storage 物件待刪清單，service_role-only
--    （supabase/functions/purge-storage 讀取＋刪除已處理的列）。
--
-- 為什麼放 public 不放 private：Edge Function 用 supabase-js＋service_role key 走
-- PostgREST，只能碰得到 [api] 曝露的 schema（預設只有 public／graphql_public，
-- supabase/config.toml 沒有加開 private）——這張表若放 private，Edge Function
-- 完全連不到它。RLS＋grant 兩層防線把它鎖死成 service_role-only，同
-- notification_events 的既有先例（20260825020000_comments_reactions_notifications.sql
-- 那段「service_role 也要明確 grant」的 merge-review 教訓：public schema 新表對
-- service_role 的預設權限只有 Dxtm，沒有 r/a/w/d，必須自己這裡補）。
--
-- 沒有 processed_at／狀態欄：這是純佇列語意，Edge Function 處理完一筆（Storage 物件
-- 確認已刪除或本來就不存在）就直接 DELETE 那一列，不留「已處理」的殘影——比對
-- notification_events 用 sent_at 標記是因為那張表的送出紀錄本身有查核價值，這裡的
-- 佇列列一旦處理完就沒有後續用途，維持愈簡單愈好（Rule 2）。物件刪除失敗（例如
-- Storage 服務短暫不可用）的列不刪，下次執行自然重試，天生冪等。
-- ---------------------------------------------------------------------------
create table public.purge_storage_queue (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null default 'media',
  object_path text not null,
  family_id uuid,
  media_id uuid,
  enqueued_at timestamptz not null default now(),
  constraint purge_storage_queue_bucket_object_key unique (bucket_id, object_path)
);

comment on table public.purge_storage_queue is
  'private.purge_expired() 硬刪 media 列之前，把 storage_path／thumb_path 收進這裡'
  '（LS-153）。supabase/functions/purge-storage（service_role）讀取、呼叫 Storage'
  ' Admin API 刪除物件，成功後直接刪掉這一列（純佇列，沒有處理狀態欄，見上方'
  ' migration 註解）。service_role-only：RLS enabled＋無 policy＋grant 只給'
  ' service_role，authenticated／anon 兩層皆無法碰。';

create index purge_storage_queue_family_idx on public.purge_storage_queue (family_id);

alter table public.purge_storage_queue enable row level security;
-- 刻意不建立任何 policy：這張表不是給任何登入使用者看的（沒有人需要知道「哪些檔案
-- 排隊等刪」），純粹是 purge_expired() 與 purge-storage Edge Function 兩支
-- service_role 身分之間的交接介面。
grant select, delete on public.purge_storage_queue to service_role;
-- 只給消化佇列實際需要的兩個動作：讀取待刪清單、確認刪除後把列拿掉；INSERT 不必
-- grant 給 service_role——寫入這張表的唯一路徑是 private.purge_expired()（SECURITY
-- DEFINER，以表擁有者 postgres 身分執行，不受這裡的 grant 影響），service_role 自己
-- 不需要、也不應該能直接塞列進去。

-- ---------------------------------------------------------------------------
-- 3. private.purge_expired(p_now) —— 主體
--
-- security definer：必須跨越全部家庭做硬刪，若受呼叫者的 RLS 限制只看得到自己家庭
-- 的資料，這支函式只能清得動呼叫者自己所屬家庭的過期列，其餘家庭永遠清不到。
--
-- 權限：不 grant 給任何人。`20260822120300_harden_default_privileges.sql` 的全域
-- default privileges（第 85/86 行）已經讓「postgres 身分之後在任何 schema 建立的
-- 新函式」對 public/anon/authenticated 天生零 EXECUTE、對 service_role 天生有
-- EXECUTE（第 93 行）——這支函式建立於那之後，直接繼承這個結果。下面仍然明確下一句
-- REVOKE，理由同 delete_my_account() 等既有 definer RPC 的一貫寫法：讓「這支函式不
-- 開放給 authenticated」這件事在檔案裡看得到，不必回頭去翻另一支 migration 才知道
-- 為什麼安全；也讓 supabase/tests/60_default_privileges.sql §2 的通掃即使有一天
-- 樣式改變，仍有這裡自己的 REVOKE 當第二層保證。pg_cron 呼叫本函式時是以排程本身
-- 的執行角色（本機／正式站的 cron.schedule() 皆以呼叫 `cron.schedule()` 當下的角色
-- 執行 job，本 migration 以 postgres 身分跑，job 因此以 postgres 執行——表擁有者，
-- 不受這裡的 REVOKE 影響）呼叫，同樣不需要額外 grant。
--
-- 每張表獨立 exception 區塊（PL/pgSQL 的 BEGIN…EXCEPTION…END 隱含 SAVEPOINT）：
-- 一張表清除失敗（理論上不該發生——沒有任何一張表的 deleted_at/deletion_requested_at
-- 硬刪路徑依賴外部服務或會拋出非預期例外，但排程是無人值守的背景工作，比照
-- 一般排程作業的慣例「一張表出事不該讓其餘五張表全部清不到」）不會讓整支函式的
-- 交易回滾，只記錄失敗、繼續清下一張表；最後仍然會成功寫入一列 purge_runs（失敗的
-- 表格 count 記 0，failed_count／failures 帶原因）。
-- ---------------------------------------------------------------------------
create or replace function private.purge_expired(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff timestamptz := p_now - interval '30 days';
  v_counts jsonb := '{}'::jsonb;
  v_failed integer := 0;
  v_failures jsonb := '[]'::jsonb;
  v_storage_enqueued integer := 0;
  v_media_deleted integer := 0;
  v_n integer;
begin
  -- diaries
  begin
    delete from public.diaries where deleted_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('diaries', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'diaries', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('diaries', 0);
  end;

  -- albums
  begin
    delete from public.albums where deleted_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('albums', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'albums', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('albums', 0);
  end;

  -- comments
  begin
    delete from public.comments where deleted_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('comments', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'comments', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('comments', 0);
  end;

  -- media：單一 SQL 陳述式（一個 WITH 鏈）同時做「刪 media 列」與「把 storage_path／
  -- thumb_path 收進佇列」，兩件事必須同生共死——只刪 media 不收路徑會讓 Storage
  -- 物件變成永遠找不回來的孤兒（沒有任何欄位還記得路徑），只收路徑不刪 media 會讓
  -- 下次執行重複收一次（ON CONFLICT DO NOTHING 擋得住重複列，但 media 列本身沒被
  -- 清到，筆數對不上）。CTE 鏈裡的 DELETE／INSERT 都是資料修改 CTE，Postgres 保證
  -- 各自恰好執行一次、且在同一個陳述式裡即使被參照多次也不會重算，最後的
  -- `select count(*) from expired, count(*) from queued` 因此能一次拿到兩個正確的
  -- 筆數，不需要額外的暫存表或陣列。
  --
  -- 額度對帳（票文要求驗證的重點）：這裡刪除的 media 列，其 deleted_at 必然已經
  -- 是「非 NULL 且早於 30 天前」（本陳述式的 WHERE 條件），代表這些列在被軟刪的
  -- 當下（deleted_at 從 NULL 變成非 NULL 那一次 UPDATE）就已經被
  -- private.media_storage_sync() 的 UPDATE 分支扣過 families.storage_used_bytes
  -- 的額度了（20260822120100_triggers.sql：UPDATE 分支對 deleted_at 從 NULL→非 NULL
  -- 的列算作「釋出」）。這裡的 DELETE 觸發同一支 trigger 的 DELETE 分支，其 SQL
  -- 明確只對 `where o.deleted_at is null` 的列計入扣除金額——這批列的 deleted_at
  -- 全部非 NULL，SUM 對它們得到的貢獻是 0，trigger 因此**不會**對這批列重複扣除
  -- 額度。這不是本 migration 新增的邏輯，是既有 trigger 的既有行為本來就正確；
  -- 101_purge_expired.sql 有一段測試直接斷言硬刪前後 storage_used_bytes 不變，
  -- 把這個「不對帳、因為本來就不需要對帳」的結論釘成可重複驗證的事實。
  begin
    with expired as (
      delete from public.media
       where deleted_at < v_cutoff
      returning id, family_id, storage_path, thumb_path
    ),
    paths as (
      select e.id as media_id, e.family_id, p.path
        from expired e,
             lateral (values (e.storage_path), (e.thumb_path)) as p(path)
       where p.path is not null
    ),
    queued as (
      insert into public.purge_storage_queue (bucket_id, object_path, family_id, media_id)
      select 'media', path, family_id, media_id from paths
      on conflict (bucket_id, object_path) do nothing
      returning 1
    )
    select (select count(*) from expired), (select count(*) from queued)
      into v_media_deleted, v_storage_enqueued;

    v_counts := v_counts || jsonb_build_object('media', v_media_deleted);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'media', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('media', 0);
  end;

  -- children：硬刪會 cascade 掉 diary_children／album_children／feed_item_children
  -- 三張連結表裡指向這個孩子的列（皆 on delete cascade，見
  -- 20260902011514_diary_album_multi_child_tags.sql／20260825020000_
  -- comments_reactions_notifications.sql）——這是刻意接受的副作用：孩子檔案永久
  -- 消失之後，任何指向它的標記本來就不該再留著，不是本函式需要額外處理的事。
  begin
    delete from public.children where deleted_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('children', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'children', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('children', 0);
  end;

  -- profiles：規格分歧與取捨 b) 的落地——見檔頭說明。硬刪會 cascade 掉
  -- family_members／reactions／device_tokens／join_requests(applicant_id)／
  -- blocked_users（雙向）五張表裡屬於這個人的列，並把 families.created_by、
  -- diaries/albums/comments 的 author_id/created_by/uploaded_by/deleted_by、
  -- invites.created_by、join_requests.resolved_by、content_reports.reporter_id、
  -- notification_events.actor_id、children.deleted_by 這些欄位 set null（全部
  -- 沒有一個是預設的 RESTRICT，逐條核對過 supabase/migrations 裡每一句
  -- `references public.profiles`，不會有任何一張表因為 FK 違反而讓這句 DELETE
  -- 失敗）。auth.users 不受影響（cascade 方向只有 auth.users → profiles，沒有反向）。
  begin
    delete from public.profiles where deletion_requested_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('profiles', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'profiles', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('profiles', 0);
  end;

  insert into private.purge_runs (p_now, deleted_counts, storage_enqueued, failed_count, failures)
  values (p_now, v_counts, v_storage_enqueued, v_failed, v_failures);

  return jsonb_build_object(
    'p_now', p_now,
    'deleted_counts', v_counts,
    'storage_enqueued', v_storage_enqueued,
    'failed_count', v_failed,
    'failures', v_failures
  );
end;
$$;

-- 只從 public／anon 收回（新函式上鎖慣例，比照 delete_my_account() 等既有 definer RPC
-- 的既有寫法——scripts/gates/migration-breaking-check.sh B3：REVOKE 名單若含
-- authenticated／service_role 等 public/anon 以外角色，會被判成「動到既有授權」的
-- BREAKING 變更，需要 PR body 的 BREAKING: 段落＋同 PR 動 docs/API.md；但這支函式從
-- 建立的第一刻就沒有對 authenticated 開放過 EXECUTE（見上方 harden_default_privileges
-- 全域預設說明），特意不 REVOKE authenticated 純粹是避免誤觸這道分級——效果上
-- authenticated 本來就沒有 EXECUTE，不需要這句話幫忙）。
revoke execute on function private.purge_expired(timestamptz) from public, anon;

comment on function private.purge_expired(timestamptz) is
  '軟刪／刪帳號請求超過 30 天的列硬刪（LS-153）。p_now 預設 now()，測試注入固定值'
  ' 驗證 29/31 天邊界。security definer，只 service_role／pg_cron（皆以 postgres'
  ' 身分執行，見上方 migration 註解）可呼叫，authenticated 沒有 EXECUTE（天生零'
  ' 授權，見 harden_default_privileges.sql 全域 default privileges，不靠這裡另外'
  ' REVOKE）。';

-- ---------------------------------------------------------------------------
-- 4. pg_cron 排程（fail-soft）
--
-- CREATE EXTENSION pg_cron 需要 shared_preload_libraries 在 Postgres 啟動時就載入
-- 該擴充，本機開發環境的映像若沒有預先設定這個啟動參數，這句話會直接噴錯（不是
-- 「裝不上但可以重試」，是這個 session／這個伺服器程序這輩子都裝不上，必須改
-- postgresql.conf 重啟）。票文要求 fail-soft，不要讓這件事擋下整條 migration
-- chain（本機／CI 的 `supabase db reset` 都要能繼續往下套用）——用 EXCEPTION
-- 吞掉，只留 NOTICE。正式站（Supabase 託管的 Postgres）pg_cron 走的是平台自己的
-- shared_preload_libraries 設定，`mcp__supabase__list_extensions` 已查證
-- pg_cron 出現在該專案的可用擴充清單（default_version 1.6.4），只是尚未
-- `installed_version`——這句 CREATE EXTENSION 在正式站預期會成功。
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      create extension pg_cron;
    exception when others then
      raise notice
        'purge_expired 排程：pg_cron 無法在本環境啟用（%），略過 cron.schedule——'
        'private.purge_expired() 函式本身仍可由 service_role 手動或外部排程呼叫',
        sqlerrm;
    end;
  end if;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      -- 19:00 UTC ≈ 台北時間凌晨 3 點，家庭相簿 app 的低流量時段。job 名稱固定，
      -- cron.schedule() 對已存在的同名 job 是更新語意（pg_cron ≥1.4），`supabase db
      -- reset` 重複套用這支 migration 不會疊出多個 job。
      perform cron.schedule('ls153-purge-expired-daily', '0 19 * * *',
        $cron$select private.purge_expired();$cron$);
    exception when others then
      raise notice 'purge_expired 排程：pg_cron 擴充已啟用，但 cron.schedule() 失敗（%），略過排程註冊', sqlerrm;
    end;
  else
    raise notice 'purge_expired 排程：pg_cron 未啟用，cron.schedule 略過（見上一段 NOTICE）';
  end if;
end;
$$;
