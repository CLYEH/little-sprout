-- LS-153 — 軟刪與刪除帳號後 30 天自動永久清除排程
--
-- 背景（票文）：docs/API.md:1263 一直明文「media 軟刪不硬刪 Storage」；children 的
-- 30 天可還原窗口（LS-66，set_child_deleted 的 LS043）與 delete_my_account()
-- （LS-143，profiles.deletion_requested_at）都留了一句「超過 30 天後的清除策略留給
-- 排程票」。這票把那句話兌現：LS-132 隱私政策要能承諾「系統於 30 天內自動永久清除」，
-- 不是「人工」。
--
-- ---------------------------------------------------------------------------
-- R2（merge-review R1 comment e71a797f，REQUEST_CHANGES：2 major 皆實測、4 minor）
-- ---------------------------------------------------------------------------
-- F1（major，reviewer 實測）：Storage 路徑入列邏輯 R1 版本只寫在
--   purge_expired() 自己那句 media DELETE 的 CTE 裡——delete_my_account()
--   情況 2（唯一成員）對 families 的 DELETE cascade 到 media 完全不經過那句
--   CTE，單人家庭刪帳號的照片 Storage 物件永遠不會被排入清除。改法：入列邏輯
--   搬進獨立的 media AFTER DELETE 統計級 trigger（transition table），
--   purge_expired() 不再自己 INSERT，見下方第 3 段。
-- F2（major，reviewer 實測）：R1 版本硬刪 profiles 之後，
--   SupabaseFamilyAPIClient.ensureProfileExists（LittleSprout/Services/Family/
--   SupabaseFamilyAPIClient.swift:51-58，`upsert(..., ignoreDuplicates: true)`）
--   對同一個尚未被 LS-151 刪除的 auth.uid() 重新插入一列全新 profiles，帳號
--   復活、deletion_requested_at 這個事實整個消失。改法（採 reviewer 建議的
--   (a)）：profiles 不再硬刪，改成 tombstone（清空 PII、標記 purged_at），
--   見下方第 4／6 段。原本這裡「孤兒帳號等同被鎖住」的論述已不適用（profiles
--   列還在，不會有孤兒 auth.users 的問題），改寫如下方新版「規格分歧 b)」。
-- minor：
--   - 孤兒 comments／reactions（diaries/albums/media/comments 被硬刪之後，
--     指向它們的留言／按讚原本會永遠留著找不到目標）→ 一併清，見第 6 段
--     purge_expired() 本體每張表區塊裡的「順帶清孤兒」段落。
--   - profiles 若撞上非預期例外（R1 假設「不會發生」，reviewer 指出這假設本身
--     不該無條件相信）不該讓整批 profiles 永遠卡住重試不動——第 6 段 profiles
--     區塊刻意不動 family_members（詳見該段註解），structurally 排除了最可能
--     撞到 owner 不變量 LS001 的路徑；既有的「每張表獨立 exception＋purge_runs
--     記錄 failures＋下次重試」設計本身已經滿足「不會永久靜默」，見第 6 段
--     檔頭與下方第 6 段「profiles」小節說明。
--   - Edge Function `purge-storage` 把 storage.remove() 沒有 error 就當整批
--     成功（連不存在的 bucket 都會被當作「處理完」而 dequeue）→ 改成逐路徑核對
--     回傳的 data 陣列，只有真的回報成功移除的路徑才 dequeue（見
--     supabase/functions/purge-storage/index.ts，本檔不變動，此處僅記錄）。
--   - 批次 200 筆／次、沒有排序、跑完一批就結束，佇列若一次超過 200 筆會永遠
--     卡住後段——Edge Function 補 `order by enqueued_at` ＋迴圈直到佇列清空或
--     達安全上限（同上，記錄於 Edge Function 檔案本身）。
-- ---------------------------------------------------------------------------
--
-- 範圍（票文 1-5，本 migration 只做「資料面＋排程」，Storage 物件的實際刪除由
-- supabase/functions/purge-storage 這支 Edge Function 消化本檔建立的佇列表）：
--   1. private.purge_expired(p_now)：diaries／albums／comments／media／children／
--      profiles 六張表，各自的 deleted_at／deletion_requested_at 超過 30 天前 → 硬刪
--      （profiles 是 tombstone，R2 起不再是硬刪，見上方 F2／下方第 4／6 段）。
--   2. media 硬刪前把 storage_path／thumb_path 收進 public.purge_storage_queue，
--      交給 Edge Function 之後刪除實體物件（此表是 service_role-only，同
--      notification_events 的既有模式）；R2 起入列邏輯是獨立 trigger，不論硬刪
--      是誰觸發的都會收到，見第 3 段。
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
--      不是「families 也要新增一個 30 天欄位」。**R2 補充**：情況 2 的 cascade
--      硬刪雖然不等 30 天，但它連坐刪掉的 media 一樣需要清 Storage 實體物件——
--      這正是 F1 修的洞，見第 3 段 trigger。
--
--   b)（R2 全部改寫，原本「刪 profiles、留孤兒 auth.users」的版本已被 F2 推翻）
--      profiles 是否該在 LS-151（Edge Function delete-account，本票開票時仍是
--      Backlog、尚未實作）完成前就處理——**採最保守解：30 天後 tombstone（清空
--      PII、標記 purged_at），不硬刪**。理由：
--        - 硬刪會被 SupabaseFamilyAPIClient.ensureProfileExists 的
--          `ignoreDuplicates: true` upsert 鑽洞復活（F2，見上方 R2 段與第 4 段
--          註解）——tombstone 讓列繼續存在，這個 upsert 走「已存在、不執行任何
--          寫入」分支，帳號復活的路徑從根本上不成立。
--        - LS-151 的職責是「立即」在 delete_my_account() 回傳後刪 auth.users
--          （docs/API.md §4 明文的 client 契約），正常路徑下 profiles 活不到 30
--          天就會隨 auth.users cascade 真正消失；這裡的 30 天處理是那條路徑
--          失敗時（client crash、網路斷線、Edge Function 本身出錯）的最後防線
--          ——隱私政策的承諾是「使用者資料 30 天內清除」，tombstone 已經把
--          display_name／avatar_url 這些使用者資料清空，不再有可辨識的 PII，
--          即使 auth.users 因為 LS-151 尚未成功而暫時還在，也不構成資料外洩。
--        - profiles.id 對 auth.users 是 `on delete cascade`（單向），tombstone
--          完全不影響這個關係——auth.users 最終消失時，tombstone 列會隨之
--          cascade 掉，不需要本票另外處理。
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
  ' {"diaries":n,"albums":n,...,"comments":n,"reactions":n} 各表硬刪／tombstone'
  ' 筆數（R2：comments／reactions 是累加值，包含自己過期＋依附在被清除的'
  ' diaries/albums/media/comments 上的孤兒清除，見 purge_expired() 函式本體）；'
  ' failed_count／failures 記錄個別表格清除失敗的次數與原因（每張表獨立'
  ' exception 區塊，一張表失敗不影響其他表照常清除）。orchestrator 巡檢用'
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
--
-- attempts／last_error／next_attempt_at（R3，merge-review R2 F1 major，comment
-- 7420f7b9 修法 (i)）：R2 版本「無法確認已刪的列永遠留在佇列、下次重試」在真的
-- 遇到無法確認的列時會變成隊頭阻塞——這些列的 enqueued_at 不會變，`order by
-- enqueued_at limit BATCH_SIZE` 每次都只讀得到它們，後面任何列都讀不到。這三欄
-- 讓 Edge Function 對「這一輪無法確認已刪」的列記錄重試次數＋退避時間，SELECT
-- 時跳過還在退避中或已達重試上限（死信／停放，不再被 SELECT 取到但保留列供
-- 稽核）的列——毒丸不再佔住隊頭，見 supabase/functions/purge-storage/index.ts。
-- ---------------------------------------------------------------------------
create table public.purge_storage_queue (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null default 'media',
  object_path text not null,
  family_id uuid,
  media_id uuid,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  next_attempt_at timestamptz,
  constraint purge_storage_queue_bucket_object_key unique (bucket_id, object_path)
);

comment on table public.purge_storage_queue is
  'media 硬刪時由 private.media_storage_queue_sync() trigger 把 storage_path／'
  ' thumb_path 收進這裡（LS-153，R2：入列邏輯從 purge_expired() 自己搬到獨立'
  ' trigger，見第 3 段，理由是 delete_my_account() 情況 2 的 cascade 硬刪不經過'
  ' purge_expired()）。supabase/functions/purge-storage（service_role）讀取、'
  ' 呼叫 Storage Admin API 刪除物件，成功後直接刪掉這一列（純佇列，沒有處理'
  ' 狀態欄，見上方 migration 註解）。service_role-only：RLS enabled＋無 policy＋'
  ' grant 只給 service_role，authenticated／anon 兩層皆無法碰。attempts／'
  ' last_error／next_attempt_at（R3）：無法確認已刪的列的重試計數／原因／下次'
  ' 可重試時間，達 5 次視為死信（停放，SELECT 略過但保留列供稽核），見'
  ' public.purge_storage_queue_mark_failed() 與 index.ts。';

-- 沒有 family_id 索引（R3，merge-review R2 F5-informational (a)）：Edge Function 是
-- 整表 `select … order by enqueued_at limit BATCH_SIZE`（見 index.ts），沒有任何
-- `family_id` 篩選，這支索引不會被任何查詢用到，只增加寫入成本——R1 建立時預留、
-- R2 review 指出沒有實際用途，migration 尚未進 development，直接移除。

alter table public.purge_storage_queue enable row level security;
-- 刻意不建立任何 policy：這張表不是給任何登入使用者看的（沒有人需要知道「哪些檔案
-- 排隊等刪」），純粹是 media_storage_queue_sync() trigger 與 purge-storage Edge
-- Function 兩支 service_role 身分之間的交接介面。
grant select, delete on public.purge_storage_queue to service_role;
-- 只給消化佇列實際需要的兩個動作：讀取待刪清單、確認刪除後把列拿掉；INSERT／UPDATE
-- 不必 grant 給 service_role——寫入這張表的唯一路徑是下面第 3 段的
-- private.media_storage_queue_sync() trigger（SECURITY DEFINER，以表擁有者
-- postgres 身分執行，不受這裡的 grant 影響）；attempts／last_error／
-- next_attempt_at 的更新一樣不直接開 UPDATE 給 service_role，改用下面
-- purge_storage_queue_mark_failed()（同樣 SECURITY DEFINER）——service_role 自己
-- 不需要、也不應該能直接塞列或改任意欄位進去，只透過這支函式表達「這幾筆這次沒能
-- 確認已刪」這個單一意圖。

-- ---------------------------------------------------------------------------
-- 2b. public.purge_storage_queue_mark_failed(p_ids, p_error) —— Edge Function 對
--    「這一輪無法確認已刪」的列記錄重試（R3，merge-review R2 F1 major，修法 (i)）。
--
-- 放 public 不放 private：與 purge_storage_queue 本身同理，Edge Function 用
-- supabase-js＋service_role key 走 PostgREST 的 `.rpc()`，只能呼叫 [api] 曝露的
-- schema（public）裡的函式。
--
-- 用一支 SECURITY DEFINER 函式而不是直接開 UPDATE 給 service_role：attempts 的
-- 遞增與 next_attempt_at 的退避計算要在同一句 UPDATE 內用舊值算新值
-- （`attempts = attempts + 1` 這類寫法只有在資料庫端才能保證原子性，PostgREST 的
-- partial update 不支援「用目前值計算新值」的表達式，呼叫端要嘛得先讀一次舊值再
-- 送新值（多一次往返＋競態窗口），要嘛就是這裡直接把「記錄一次失敗」整個動作包成
-- 一支函式）。
--
-- 退避公式：`2^(次數)` 分鐘（用位元左移避免浮點數）。**R4（merge-review R3
-- minor 3，comment `04987043`）文字修正，不動行為**：這裡的指數在
-- `least(attempts + 1, 10)` 就被壓住，`1 << 10 = 1024`，外層
-- `least(..., 1440)` 那個「1440 分鐘（24 小時）」的分支因此永遠走不到——真正的
-- 理論上限是 1024 分鐘（約 17.07 小時），不是 24 小時（reviewer 實測：
-- attempts 9／10／11／20 得到的 `next_attempt_at` 差值恆為 1024 分鐘）。而且
-- 因為 SELECT 端 `attempts < MAX_ATTEMPTS` 在達到門檻後就不會再選到這一列，
-- **實際能觀察到的最大退避是 32 分鐘**（`MAX_ATTEMPTS`＝5，第 4→5 次失敗那次
-- `2^5`）——1024 分鐘那個上限本身也永遠用不到，純粹是公式本身的數學極限。達
-- `MAX_ATTEMPTS`（Edge Function 端的常數，見 index.ts，目前 5）次之後這裡不特別
-- 處理停放判定——「停放」完全靠 Edge Function 的 SELECT 端 `where attempts <
-- MAX_ATTEMPTS`（見 index.ts），這支函式只負責老實記錄「又失敗了一次、原因是
-- 什麼」，不需要知道死信門檻設在哪裡（門檻是 Edge Function 的執行策略，不是這張
-- 佇列表的資料完整性規則，兩者刻意不耦合）。
-- ---------------------------------------------------------------------------
create or replace function public.purge_storage_queue_mark_failed(p_ids uuid[], p_error text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.purge_storage_queue
     set attempts = attempts + 1,
         last_error = p_error,
         next_attempt_at = now() + (least(1 << least(attempts + 1, 10), 1440) || ' minutes')::interval
   where id = any(p_ids);
$$;

comment on function public.purge_storage_queue_mark_failed(uuid[], text) is
  'Edge Function（supabase/functions/purge-storage）對這一輪無法確認已刪的'
  ' purge_storage_queue 列記錄重試（R3，LS-153，merge-review R2 F1）：attempts'
  ' 遞增、last_error 記原因、next_attempt_at 依指數退避（2^attempts 分鐘，公式'
  ' 本身的理論上限 1024 分鐘；MAX_ATTEMPTS=5 之下實際最大退避是 32 分鐘，R4'
  ' 文字修正見上方函式註解）設定下次可重試時間。SECURITY DEFINER：service_role'
  ' 只能透過這支函式表達「這幾筆這次沒能確認已刪」，不能直接 UPDATE 任意欄位。';

revoke execute on function public.purge_storage_queue_mark_failed(uuid[], text) from public, anon;
-- 只從 public／anon 收回，不寫 authenticated（比照 private.purge_expired() 收尾
-- 那句 REVOKE 的既有寫法與理由，見該處註解）：scripts/gates/migration-breaking-
-- check.sh 會把「REVOKE 名單含 authenticated」判成動到既有授權的 BREAKING 變更
-- （需要 PR body BREAKING: 段落＋同 PR 動 docs/API.md）；但這支函式從建立的第一刻
-- 就沒有對 authenticated 開放過 EXECUTE（全域 default privileges，見
-- harden_default_privileges.sql），特意不 REVOKE authenticated 純粹是避免誤觸這道
-- 分級——效果上 authenticated 本來就沒有 EXECUTE，不需要這句話幫忙。

-- ---------------------------------------------------------------------------
-- 3. media 的 AFTER DELETE 統計級 trigger：硬刪時把 storage_path／thumb_path 收進
--    purge_storage_queue（R2，merge-review R1 F1，comment e71a797f，reviewer 已
--    實測）。
--
-- R1 的做法（入列邏輯寫在 purge_expired() 自己那句 media DELETE 的 CTE 裡）有一個
-- 洞：public.media 被硬刪的路徑不是只有 purge_expired() 自己那句
-- `delete from public.media where deleted_at < v_cutoff`——delete_my_account()
-- （LS-143）情況 2（呼叫者是某家庭的唯一成員）在 RPC 呼叫的當下就對 `families`
-- 下一句 DELETE，FK on delete cascade 一路連坐到 media，這條路徑完全不經過
-- purge_expired()，R1 版本的入列邏輯因此完全不會被觸發——單人家庭刪帳號留下的
-- 照片，Storage 佇列永遠是 0 列，物件實體永遠不會被清除。
--
-- 修法：入列邏輯搬進一支獨立的 AFTER DELETE 統計級（statement-level）trigger，
-- 掛在 media 本身，用 transition table 讀被刪的整批列——這樣不論這批 DELETE 是
-- purge_expired() 自己執行，還是被某個上游 DELETE（families／...）cascade 觸發，
-- Postgres 都會在 media 這個層級補一次 AFTER DELETE 事件，trigger 都會執行到
-- （reviewer 已用本機映像實測：對 families 直接 DELETE 觸發 media 的 cascade，
-- 這支 trigger 確實收到路徑並成功入列；本檔既有的 private.media_storage_sync()／
-- private.feed_sync_albums() 等既有 trigger 一貫是同一種行為——cascade delete
-- 一樣會讓子表的 AFTER DELETE trigger 跑，20260903084231_delete_account.sql 測試
-- 3 的 feed_items 斷言已經間接證明過同一件事）。purge_expired() 的 media 區塊
-- 因此改成單純 `delete from public.media where ...`，入列這件事完全交給這支
-- trigger，不再自己 INSERT——避免同一批路徑被兩個地方各寫一次（雙寫）。
--
-- 為什麼是「硬刪就入列，不看 deleted_at 是否非 NULL」：情況 2 的 cascade 硬刪對象
-- 不限於已軟刪的 media（唯一成員刪帳號時，家庭底下所有照片不論軟刪與否都會被
-- cascade 掉），這些照片的 Storage 物件同樣該被清掉——這支 trigger 因此對「任何
-- 硬刪的 media 列」都入列，不像 purge_expired() 自己那句 DELETE 只挑 deleted_at
-- 過期的列，兩者用途不同、判準本來就該不同。
-- ---------------------------------------------------------------------------
create or replace function private.media_storage_queue_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.purge_storage_queue (bucket_id, object_path, family_id, media_id)
  select 'media', p.path, o.family_id, o.id
    from old_rows o,
         lateral (values (o.storage_path), (o.thumb_path)) as p(path)
   where p.path is not null
  on conflict (bucket_id, object_path) do nothing;
  return null;
end;
$$;

comment on function private.media_storage_queue_sync() is
  'media 硬刪時（不論是 purge_expired() 自己的 DELETE 還是上游 cascade，例如'
  ' delete_my_account() 情況 2 對 families 的 DELETE 連坐）把 storage_path／'
  ' thumb_path 收進 public.purge_storage_queue（R2，merge-review R1 F1）。統計級'
  ' AFTER DELETE＋transition table：cascade delete 一樣會觸發這個層級的事件，不會'
  ' 因為刪除是從上游表發起就漏收。';

create trigger media_storage_queue_sync
  after delete on public.media
  referencing old table as old_rows
  for each statement execute function private.media_storage_queue_sync();

-- ---------------------------------------------------------------------------
-- 4. profiles.purged_at —— 支撐「tombstone 而非硬刪」（R2，merge-review R1 F2，
--    comment e71a797f，reviewer 已實測帳號復活洞）。
--
-- R1 對 profiles 的做法是超過 30 天直接 `DELETE FROM public.profiles`。reviewer
-- 實測出一個帳號復活洞：SupabaseFamilyAPIClient.ensureProfileExists
-- （LittleSprout/Services/Family/SupabaseFamilyAPIClient.swift:51-58）用
-- `upsert(payload, onConflict: "id", ignoreDuplicates: true)`——PostgREST 端等同
-- `insert ... on conflict (id) do nothing`。profiles 列若已被硬刪（id 不存在），
-- 這句 upsert 會走「不存在」那個分支，對同一個 auth.uid()（此時 auth.users 尚未
-- 被 LS-151 的 delete-account Edge Function 刪除，仍然是合法的登入身份）直接插入
-- 一列全新的 profiles（deletion_requested_at 預設 NULL）——帳號看起來「復活」了，
-- 而且原本「已請求刪除」這個事實整個消失，下一次 30 天窗口也不會再把它挑出來。
--
-- 修法（reviewer 建議 (a)，優先採用，不新增 policy 面、與 LS-151「client 立即
-- 呼叫 delete-account 刪 auth.users」的既有契約相容）：profiles 不再硬刪，改成
-- tombstone——清空 PII 欄位（display_name／avatar_url），purged_at 標記已經
-- tombstone 過。因為列本身**還在**（只是內容變成佔位符），ensureProfileExists 的
-- `ignoreDuplicates: true` 這時走的是「已存在，整句 upsert 不執行任何寫入」那個
-- 分支——不會覆寫 tombstone 內容，更不會讓 deletion_requested_at／purged_at 被清
-- 掉（這兩欄本來就沒有對 authenticated 開放 UPDATE，見
-- 20260903084231_delete_account.sql 的欄位級 grant 收斂，client 這句 upsert
-- 連想動都動不了這兩欄）。真正把這個帳號徹底移除交給 LS-151：delete-account
-- Edge Function 以 service_role 刪除 auth.users，profiles.id references
-- auth.users(id) on delete cascade 這時才會讓 tombstone 列連同 auth 身份一起消失。
--
-- purged_at 存在的理由（不能只看 deletion_requested_at 判斷「有沒有 tombstone
-- 過」）：deletion_requested_at 本身不會變、也不該被清掉（它是「使用者何時請求
-- 刪除」這個事實的永久記錄），需要一個獨立欄位標記「tombstone 這個動作本身有沒有
-- 做過」，purge_expired() 才能只對「還沒 tombstone 過」的列動作，不會每天對同一批
-- 已經是佔位符內容的列重複 UPDATE（冪等，見第 6 段 profiles 區塊的 WHERE 條件）。
-- ---------------------------------------------------------------------------
alter table public.profiles add column purged_at timestamptz;

comment on column public.profiles.purged_at is
  'private.purge_expired() 把 PII（display_name／avatar_url）改成佔位符的時間'
  '（R2，LS-153）。NULL＝尚未 tombstone。不是硬刪：profiles 列本身保留，阻止'
  ' SupabaseFamilyAPIClient.ensureProfileExists 的 ignoreDuplicates upsert 重新'
  ' 插入一列造成帳號復活（見 migration 第 4 段）。真正的實體清除是 auth.users'
  ' 被 LS-151 的 delete-account Edge Function 刪除時的 cascade。authenticated'
  ' 對這一欄沒有 UPDATE 權限（沿用 profiles 整表已收回、只重開'
  ' display_name／avatar_url 兩欄的既有慣例，見 20260903084231_delete_account.sql）。';

-- ---------------------------------------------------------------------------
-- 5. private.purge_expired(p_now) —— 主體
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
-- 表格 count 記 0，failed_count／failures 帶原因）——**這個設計本身已經滿足
-- reviewer minor finding「purge_runs 記 failure 明細＋下次重試」**：WHERE 條件是
-- 冪等的（不會因為失敗而標記「已嘗試過」），下次排程執行會用同一個判準自然重新挑到
-- 還沒清乾淨的列，不需要額外的重試佇列或退避機制。
--
-- 每個表格區塊內「先算完所有 DML、最後才把結果併入外層累加器」的寫法（R2 新增，
-- 因為 R2 起有些區塊要做兩件以上的事——刪主表列＋清孤兒 comments／reactions）：
-- 外層累加器（v_counts／v_comments_total／v_reactions_total／v_storage_enqueued）
-- 只在區塊內的 DML 全部沒有拋例外、真正執行到區塊最後一行時才更新；一旦中途拋出
-- 例外，控制權直接跳到 EXCEPTION 分支，這些外層變數完全不會被動到。這樣不會出現
-- 「summary 數字顯示清了，但因為 SAVEPOINT 回滾其實資料庫裡什麼都沒變」的落差——
-- PL/pgSQL 的區域變數賦值不是交易性的（不會隨 SAVEPOINT 一起回滾），若在 DML
-- 途中就更新累加器，例外發生時外層變數會殘留一個資料庫沒有真的發生過的假象。
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
  v_comments_total integer := 0;
  v_reactions_total integer := 0;
  v_n integer;
  v_ids uuid[];
  v_local_comments integer;
  v_local_reactions integer;
  v_queue_before integer;
  v_queue_after integer;
  -- R3（merge-review R2 F2／F3）：孤兒留言自己的 id（供清它們的 reactions／
  -- content_reports）；v_n2 是這一段「順帶再清一層」的列數暫存，不與 v_n（主表
  -- 清除筆數，函式最後要寫進 v_counts）共用，避免互相覆寫。
  v_orphan_comment_ids uuid[];
  v_n2 integer;
begin
  -- diaries：硬刪之後順帶清掉指向這篇日記的孤兒 comments／reactions／
  -- content_reports／notification_events（多型關聯，沒有 FK，父列消失不會自動
  -- 帶走它們，見 PLAN §5「無法下外鍵」的既有代價）。R3（merge-review R2
  -- F2／F3）：孤兒留言被清掉之後，指向「那則留言」的按讚會變成第二層孤兒（留言
  -- 消失了，但誰對它按過讚的紀錄還在）——用 `delete … returning id` 把孤兒留言
  -- 自己的 id 收出來，再多清一次 target_type='comment' 的 reactions；檢舉
  -- （content_reports）指向已永久清除的日記本身、或指向已被連坐清除的孤兒留言，
  -- orchestrator 裁定一併清除——票的承諾是「永久清除」，檢舉紀錄不該是唯一
  -- 例外（見 docs/API.md §6）。**R4（merge-review R3 minor 1，comment
  -- `04987043`）**：`notification_events` 是第五張同樣的多型孤兒表
  -- （`target_type`／`target_id` 欄位形狀與 `content_reports` 完全相同，見
  -- `20260825020000_comments_reactions_notifications.sql`），R3 只處理了
  -- `content_reports`——reviewer 實測指出這句「不該是唯一例外」的話對
  -- `notification_events` 同樣不成立，一併清除，與 `content_reports` 同形。
  begin
    with deleted as (
      delete from public.diaries where deleted_at < v_cutoff returning id
    )
    select coalesce(array_agg(id), array[]::uuid[]) into v_ids from deleted;
    v_n := coalesce(array_length(v_ids, 1), 0);

    v_local_comments := 0;
    v_local_reactions := 0;
    if v_n > 0 then
      with orphan_comments as (
        delete from public.comments where target_type = 'diary' and target_id = any(v_ids) returning id
      )
      select coalesce(array_agg(id), array[]::uuid[]) into v_orphan_comment_ids from orphan_comments;
      v_local_comments := coalesce(array_length(v_orphan_comment_ids, 1), 0);

      delete from public.reactions where target_type = 'diary' and target_id = any(v_ids);
      get diagnostics v_local_reactions = row_count;

      delete from public.content_reports where target_type = 'diary' and target_id = any(v_ids);
      delete from public.notification_events where target_type = 'diary' and target_id = any(v_ids);

      if v_local_comments > 0 then
        delete from public.reactions where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        get diagnostics v_n2 = row_count;
        v_local_reactions := v_local_reactions + v_n2;

        delete from public.content_reports where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        delete from public.notification_events where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
      end if;
    end if;

    v_counts := v_counts || jsonb_build_object('diaries', v_n);
    v_comments_total := v_comments_total + v_local_comments;
    v_reactions_total := v_reactions_total + v_local_reactions;
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'diaries', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('diaries', 0);
  end;

  -- albums：同上，target_type = 'album'。
  begin
    with deleted as (
      delete from public.albums where deleted_at < v_cutoff returning id
    )
    select coalesce(array_agg(id), array[]::uuid[]) into v_ids from deleted;
    v_n := coalesce(array_length(v_ids, 1), 0);

    v_local_comments := 0;
    v_local_reactions := 0;
    if v_n > 0 then
      with orphan_comments as (
        delete from public.comments where target_type = 'album' and target_id = any(v_ids) returning id
      )
      select coalesce(array_agg(id), array[]::uuid[]) into v_orphan_comment_ids from orphan_comments;
      v_local_comments := coalesce(array_length(v_orphan_comment_ids, 1), 0);

      delete from public.reactions where target_type = 'album' and target_id = any(v_ids);
      get diagnostics v_local_reactions = row_count;

      delete from public.content_reports where target_type = 'album' and target_id = any(v_ids);
      delete from public.notification_events where target_type = 'album' and target_id = any(v_ids);

      if v_local_comments > 0 then
        delete from public.reactions where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        get diagnostics v_n2 = row_count;
        v_local_reactions := v_local_reactions + v_n2;

        delete from public.content_reports where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        delete from public.notification_events where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
      end if;
    end if;

    v_counts := v_counts || jsonb_build_object('albums', v_n);
    v_comments_total := v_comments_total + v_local_comments;
    v_reactions_total := v_reactions_total + v_local_reactions;
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'albums', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('albums', 0);
  end;

  -- comments：自己過期的一併算進 v_comments_total（不在這裡直接寫
  -- v_counts.comments，那個鍵在函式最後才用累加後的總數一次寫入，見函式尾端）。
  -- 硬刪之後同樣要清孤兒 reactions（有人在這則留言按讚），以及防禦性地清「以這則
  -- 留言為 target 的其他 comments」——content_target_type 的 'comment' 值目前
  -- 唯一的實際用途是 content_reports 檢舉留言（20260822120000_init_schema.sql
  -- 對這個 enum 值的既有註解），本產品沒有留言回覆留言的功能（comments 沒有
  -- parent_comment_id 欄位），這段今天預期永遠是 0 筆——保留是因為多型 target
  -- 沒有 FK，寧可多做一次涵蓋，也不要在未來真的長出留言串功能時變成一個沒被
  -- 想到的孤兒來源。
  begin
    with deleted as (
      delete from public.comments where deleted_at < v_cutoff returning id
    )
    select coalesce(array_agg(id), array[]::uuid[]) into v_ids from deleted;
    v_n := coalesce(array_length(v_ids, 1), 0);

    v_local_comments := v_n;
    v_local_reactions := 0;
    if v_n > 0 then
      delete from public.reactions where target_type = 'comment' and target_id = any(v_ids);
      get diagnostics v_local_reactions = row_count;

      -- R3（merge-review R2 F3）：檢舉指向這則已永久清除的留言本身也一併清除，
      -- 理由同上方 diaries／albums 區塊。R4（merge-review R3 minor 1）：
      -- notification_events 同理。
      delete from public.content_reports where target_type = 'comment' and target_id = any(v_ids);
      delete from public.notification_events where target_type = 'comment' and target_id = any(v_ids);

      declare
        v_nested_comments integer;
      begin
        delete from public.comments where target_type = 'comment' and target_id = any(v_ids);
        get diagnostics v_nested_comments = row_count;
        v_local_comments := v_local_comments + v_nested_comments;
      end;
    end if;

    v_comments_total := v_comments_total + v_local_comments;
    v_reactions_total := v_reactions_total + v_local_reactions;
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'comments', 'error', sqlerrm);
  end;

  -- media：只刪列，不自己入列 Storage 佇列——private.media_storage_queue_sync()
  -- trigger（第 3 段）會在這句 DELETE 觸發的 AFTER DELETE 事件裡自動處理，不論這句
  -- DELETE 是這裡執行還是被上游 cascade 觸發（R2 F1）。storage_enqueued 用「這句
  -- DELETE 前後 purge_storage_queue 的列數差」推算——這支函式沒有直接呼叫 INSERT，
  -- 沒有 GET DIAGNOSTICS 可以直接問 trigger 插入了幾筆；同一交易內先後兩次
  -- COUNT(*) 的差值，在没有其他併發 session 同時對 media 做硬刪的情況下就是這次
  -- DELETE 觸發入列的筆數（純觀測用途，不影響刪除本身的正確性——即使剛好有其他
  -- session 同時硬刪、把這個差值算大了一點，purge_runs.storage_enqueued 也只是
  -- 一個近似的觀測欄位，不是任何下游邏輯的輸入）。硬刪之後同樣清孤兒
  -- comments／reactions（有人在這張照片下留言／按讚）。
  begin
    select count(*) into v_queue_before from public.purge_storage_queue;

    with deleted as (
      delete from public.media where deleted_at < v_cutoff returning id
    )
    select coalesce(array_agg(id), array[]::uuid[]) into v_ids from deleted;
    v_n := coalesce(array_length(v_ids, 1), 0);

    select count(*) into v_queue_after from public.purge_storage_queue;

    v_local_comments := 0;
    v_local_reactions := 0;
    if v_n > 0 then
      with orphan_comments as (
        delete from public.comments where target_type = 'media' and target_id = any(v_ids) returning id
      )
      select coalesce(array_agg(id), array[]::uuid[]) into v_orphan_comment_ids from orphan_comments;
      v_local_comments := coalesce(array_length(v_orphan_comment_ids, 1), 0);

      delete from public.reactions where target_type = 'media' and target_id = any(v_ids);
      get diagnostics v_local_reactions = row_count;

      -- R3（merge-review R2 F3）：孤兒留言與檢舉，理由同 diaries／albums 區塊。
      -- R4（merge-review R3 minor 1）：notification_events 同理。
      delete from public.content_reports where target_type = 'media' and target_id = any(v_ids);
      delete from public.notification_events where target_type = 'media' and target_id = any(v_ids);

      if v_local_comments > 0 then
        delete from public.reactions where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        get diagnostics v_n2 = row_count;
        v_local_reactions := v_local_reactions + v_n2;

        delete from public.content_reports where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
        delete from public.notification_events where target_type = 'comment' and target_id = any(v_orphan_comment_ids);
      end if;
    end if;

    v_counts := v_counts || jsonb_build_object('media', v_n);
    v_storage_enqueued := v_storage_enqueued + greatest(v_queue_after - v_queue_before, 0);
    v_comments_total := v_comments_total + v_local_comments;
    v_reactions_total := v_reactions_total + v_local_reactions;
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
  -- children 不是 content_target_type 的合法值，不會有孤兒 comments／reactions
  -- 指向孩子檔案本身，這裡不需要跟上面四張表一樣的孤兒清除步驟。
  begin
    delete from public.children where deleted_at < v_cutoff;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object('children', v_n);
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'children', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('children', 0);
  end;

  -- profiles（R2 全面改寫，F2）：tombstone 而非硬刪——見第 4 段對
  -- ensureProfileExists 帳號復活洞的完整說明。WHERE 條件多了 `purged_at is null`：
  -- 已經 tombstone 過的列不會被重複挑中，UPDATE 只對「這一次真正的狀態轉換」
  -- 執行，冪等重跑不會對同一批列一直寫入同樣的佔位符（也不會讓 v_counts.profiles
  -- 每天都顯示「又清了一次」）。
  --
  -- 硬刪 reactions／device_tokens／join_requests(applicant_id)／blocked_users
  -- （雙向）——這四張表原本靠 profiles 硬刪的 FK cascade 自動清掉，改成 tombstone
  -- 之後 cascade 不會觸發，這裡手動補（否則會變成永久留著的殘影：一個已經是
  -- 佔位符內容的帳號，卻還留著按讚記錄／推播 token／待審申請／封鎖名單，沒有
  -- 意義，其中 device_tokens 更是實質問題——「已刪除」的帳號不該還收得到推播）。
  --
  -- **刻意不動 family_members**（reviewer minor finding：profiles 清除不該撞上
  -- owner 不變量 LS001）：delete_my_account()（LS-143）呼叫成功之後，
  -- family_members 對這個 uid 本來就應該已經是 0 列——情況 2（唯一成員）連同
  -- 整個家庭 cascade 掉，情況 3（一般成員）在 RPC 呼叫的當下就同步執行
  -- `DELETE FROM family_members WHERE user_id = v_uid`。這裡若還手動對
  -- family_members 下 DELETE，理論上永遠是 0 列 no-op，但萬一哪天真的因為非
  -- 預期的 bug 讓某個 uid 在 deletion_requested_at 已設定的情況下仍留著
  -- family_members 列，這句 DELETE 會觸發 enforce_family_has_owner() 這顆既有
  -- trigger，若這個人剛好是那個家庭僅存的 owner，會直接 raise LS001，把整個
  -- profiles 區塊（含這一整批要 tombstone 的其他無關列）都因為 SAVEPOINT 回滾
  -- 卡住、每天重試每天失敗——不觸碰 family_members 從結構上排除這個風險，
  -- family_members 的正確性交給 delete_my_account() 自己的既有測試覆蓋
  -- （supabase/tests/91_delete_account.sql），不是這支函式的責任範圍。
  begin
    with tombstoned as (
      update public.profiles
         set display_name = '已刪除的帳號', avatar_url = null, purged_at = now()
       where deletion_requested_at < v_cutoff and purged_at is null
      returning id
    )
    select coalesce(array_agg(id), array[]::uuid[]) into v_ids from tombstoned;
    v_n := coalesce(array_length(v_ids, 1), 0);

    v_local_reactions := 0;
    if v_n > 0 then
      delete from public.reactions where user_id = any(v_ids);
      get diagnostics v_local_reactions = row_count;

      delete from public.device_tokens where user_id = any(v_ids);
      delete from public.join_requests where applicant_id = any(v_ids);
      delete from public.blocked_users where blocker_id = any(v_ids) or blocked_id = any(v_ids);
    end if;

    v_counts := v_counts || jsonb_build_object('profiles', v_n);
    v_reactions_total := v_reactions_total + v_local_reactions;
  exception when others then
    v_failed := v_failed + 1;
    v_failures := v_failures || jsonb_build_object('table', 'profiles', 'error', sqlerrm);
    v_counts := v_counts || jsonb_build_object('profiles', 0);
  end;

  -- comments／reactions 是跨區塊累加值（自己過期＋孤兒清除），到這裡才一次寫入。
  v_counts := v_counts || jsonb_build_object('comments', v_comments_total, 'reactions', v_reactions_total);

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
  '軟刪／刪帳號請求超過 30 天的列硬刪（media／children／diaries／albums／comments）'
  ' 或 tombstone（profiles，R2 起不再硬刪，見第 4／6 段）。p_now 預設 now()，測試'
  ' 注入固定值驗證 29/31 天邊界。security definer，只 service_role／pg_cron（皆以'
  ' postgres 身分執行，見上方 migration 註解）可呼叫，authenticated 沒有 EXECUTE'
  '（天生零授權，見 harden_default_privileges.sql 全域 default privileges，這支'
  ' 函式的收回動作只補了 public／anon 兩個角色，見上一句）。';

-- ---------------------------------------------------------------------------
-- 6. pg_cron 排程（fail-soft）
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
