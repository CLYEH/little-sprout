-- LS-172（LS-22 後端子票）— Edge Function push-dispatch 的資料面支援：兩支
-- service_role-only 的 SECURITY DEFINER RPC（claim_notification_events／
-- notification_recipients），以及 device_tokens 的一個補充 grant（失效 token 清除）。
--
-- ---------------------------------------------------------------------------
-- 規格分歧與取捨（逐項記錄，不只留最終狀態——同 purge_expired／delete_account
-- 系列 migration 的既有慣例）
--
-- 1.（**關鍵**）函式落在 `public` schema，不是票文字面的 `private.claim_notification_
--    events`／`private.notification_recipients`：`supabase/config.toml` 的
--    `[api] schemas = ["public", "graphql_public"]`——PostgREST 只把這兩個 schema
--    的物件掛上 `/rest/v1/` 端點，`private` schema 完全不可見。既有的
--    `private.purge_expired()`／`private.record_notification_event()` 之所以能留在
--    `private`，是因為呼叫方分別是 `pg_cron`（直接 SQL，見
--    `20260903110908_purge_expired.sql`）與同一支 migration 內的 trigger（同一個
--    交易內的函式呼叫）——兩者都不經過 PostgREST。本票的呼叫方是 Edge Function
--    用 `supabase-js` 的 `.rpc()`（比照既有的 `finalize_account_deletion`／
--    `purge_storage_queue_mark_failed`，見 `delete-account`／`purge-storage` 兩支
--    既有 Edge Function 的 `index.ts`），這條路徑**必須**是 `public` schema 的函式
--    才可能被叫到——若照票文字面放 `private`，Edge Function 呼叫會直接拿到
--    PostgREST「函式不存在」的錯誤，push-dispatch 整支票會是空的。授權邊界不靠
--    schema（`private` 這個 schema 名字本身不是安全邊界，這個 repo 從
--    `harden_default_privileges.sql` 起就是這樣：安全邊界永遠是 GRANT／REVOKE），
--    靠的是下面第 3 段的「只 grant service_role」——與 `finalize_account_deletion`
--    （`public` schema、也是只給 `service_role`）同一種形狀，只是換了個 schema 名字，
--    語意（「不對外」）不變。
-- 2. **沒有新增「待送列部分索引」**：票文第 2 項要求「notification_events 加一個
--    待送列的部分索引（WHERE sent_at IS NULL，配合 occurred_at 排序／過濾）」——但
--    這正是既有的 `notification_events_pending_idx`
--    （`on public.notification_events (occurred_at) where sent_at is null`，見
--    `20260825020000_comments_reactions_notifications.sql` 第 3 段）已經提供的形狀，
--    與下面 `claim_notification_events()` 的查詢（`where sent_at is null and
--    occurred_at < now() - interval '5 minutes' order by occurred_at limit n`）
--    完全吻合。加一個內容重複的索引沒有任何額外效益，只會多付維護成本（每次
--    INSERT/UPDATE 多寫一份、多佔儲存），這裡選擇不重複造，用 `EXPLAIN` 在本機
--    驗證過既有索引確實被選中（見票 handoff）。LS-58 落地這張表時就已經預留了
--    「Edge Function（LS-22）掃描待送事件用」這個用途（索引本身的既有註解就是這樣
--    寫的），本票只是第一個真的用到它的呼叫方。
-- 3. 兩支函式都不對 `authenticated` 額外 `revoke`（只從 `public`／`anon` 收回）——
--    比照 `private.purge_expired()` 的既有理由（見該 migration 檔尾）：這兩支函式
--    從建立的第一刻就沒有對 `authenticated` 開放過 `EXECUTE`
--    （`harden_default_privileges.sql` 的全域 default privileges 已經把新函式的
--    `PUBLIC` baseline 收掉，`authenticated` 是 `PUBLIC` 的成員，從未經由它拿到過
--    這兩支函式的執行權）；特意不 `REVOKE authenticated` 純粹是避免誤觸
--    `scripts/gates/migration-breaking-check.sh` 的 B3 規則（REVOKE 名單含
--    `public`／`anon` 以外的角色即判 BREAKING），不是安全考量的差異。`service_role`
--    的 `EXECUTE` 同樣不需要另外 `grant`——`harden_default_privileges.sql` 的
--    `alter default privileges grant execute on functions to service_role;`
--    （不限 schema）已經涵蓋新函式，這裡的 `revoke` 只是把 `public`／`anon`
--    這兩個「本來就沒有、但顯式聲明更清楚」的角色寫清楚，比照
--    `private.purge_expired()` 的既有寫法。
-- 4. `device_tokens` 新增 `grant select (token), delete ... to service_role`——同
--    `notification_events` 的既有教訓（該表的 grant 註解已經指出：public schema 表
--    對 `service_role` 的預設權限**不含** SELECT/INSERT/UPDATE/DELETE，只有
--    TRUNCATE/REFERENCES/TRIGGER/MAINTAIN，本機 `\dp` 已實測過）。push-dispatch
--    收到 APNs 回報的失效 token（410 Unregistered／`BadDeviceToken`）時要能直接
--    `DELETE ... WHERE token = $1` 那一列。**本機 psql 實測踩出一個原本以為「只給
--    DELETE 就夠」的洞**：PostgreSQL 對帶 `WHERE` 條件的 `DELETE` 要求呼叫者對
--    `WHERE` 子句引用到的欄位也要有 `SELECT` 權限（否則無法評估條件式），單純
--    `grant delete` 會撞 `permission denied for table device_tokens`（hint 正是
--    「Grant SELECT」）——這裡改成欄位級 `select (token)`（比照 `profiles` 的
--    `select (id, deletion_requested_at)` 既有慣例，只開 `WHERE` 用得到的那一欄，
--    不給 `user_id`／`platform`／`updated_at`）＋整表 `delete`；不給
--    `INSERT`／`UPDATE`：Edge Function 從不需要新增或改動既有的 token 綁定（那是
--    `register_device_token` RPC 的職責），也不需要讀出其他欄位（待送對象清單來自
--    下面的 `notification_recipients()`，本身是 SECURITY DEFINER，不受這個 grant
--    影響）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. claim_notification_events(p_limit)：先 claim 再送的取件函式
--
-- 語意（票文明定）：`sent_at IS NULL AND occurred_at < now() - interval '5 minutes'`
-- 才算「視窗已穩定」（5 分鐘滾動視窗合併規則見
-- `20260825020000_comments_reactions_notifications.sql`——若視窗還沒過 5 分鐘就取走，
-- 之後同一個 target 的新事件會因為找不到「還沒送出的」既有列而另開一筆，導致同一波
-- 動作被拆成兩則通知）。標記 `sent_at = now()` 即視為冪等鎖：即使這一列之後在 Edge
-- Function 內送出失敗，也**不回滾** `sent_at`——寧可漏送不重送（票文明定的取捨，
-- 同時寫進 docs/API.md，供未來調整時對照）。
--
-- 併發安全：`FOR UPDATE SKIP LOCKED` 是標準的「多個 worker 同時 claim 同一張佇列
-- 表」寫法——兩個幾乎同時的呼叫（例如排程重疊、或本票要求的「claim 兩次」測試）
-- 各自鎖住自己選到的列，後到的呼叫會跳過已被鎖住的列，選到其餘尚未被鎖的列，不會
-- 兩邊都選到同一列。子查詢（`candidates`）只做 `SELECT ... FOR UPDATE SKIP LOCKED`
-- 取得列 id，真正的 `UPDATE ... FROM candidates ... RETURNING` 才是實際標記
-- `sent_at` 的地方——`UPDATE ... FROM (SELECT ... FOR UPDATE SKIP LOCKED)` 是
-- PostgreSQL 官方文件與社群公認的 claim-based queue 標準寫法，一次 SQL 語句內完成
-- 「挑選＋鎖定＋標記＋回傳」，不需要额外的交易邊界。
--
-- `actor_display_name` 在這裡（SECURITY DEFINER，繞過 `service_role` 對
-- `public.profiles` 只有欄位級 `select (id, deletion_requested_at)` 的既有限制，見
-- `20260903115014_delete_account_edge_support.sql`）用 `COALESCE(display_name,
-- '家人')` 算好回傳——票文明定「actor_id 為 NULL 時 fallback「家人」」；
-- `profiles.display_name` 依既有 schema 保證非空（新建立由 trigger 推導、
-- tombstone 由 `purge_expired()` 寫成固定文案「已刪除的帳號」，兩者都不是
-- NULL／空字串，見 `docs/API.md` §3 `profiles`），唯一會拿到 NULL 的情況是
-- `actor_id` 本身是 NULL（`LEFT JOIN` 對不到任何 `profiles` 列——例如觸發事件的
-- 使用者之後整個帳號被硬刪，`notification_events.actor_id` 依既有 FK
-- `on delete set null` 變成 NULL），這裡的 `COALESCE` 一次涵蓋兩種情況
-- （`actor_id IS NULL` 與理論上不該發生但防禦性涵蓋的「查得到 `actor_id` 卻查不到
-- `profiles` 列」）。
-- ---------------------------------------------------------------------------

create or replace function public.claim_notification_events(p_limit integer default 50)
returns table (
  id uuid,
  family_id uuid,
  kind public.notification_kind,
  target_type public.content_target_type,
  target_id uuid,
  actor_id uuid,
  actor_display_name text,
  event_count integer,
  occurred_at timestamptz
)
language sql
security definer
set search_path = ''
as $$
  with candidates as (
    select ne.id
      from public.notification_events ne
     where ne.sent_at is null
       and ne.occurred_at < now() - interval '5 minutes'
     order by ne.occurred_at
     limit least(greatest(coalesce(p_limit, 50), 1), 500)
     for update skip locked
  ),
  claimed as (
    update public.notification_events e
       set sent_at = now()
      from candidates c
     where e.id = c.id
       and e.sent_at is null
    returning e.id, e.family_id, e.kind, e.target_type, e.target_id, e.actor_id,
              e.event_count, e.occurred_at
  )
  select c.id, c.family_id, c.kind, c.target_type, c.target_id, c.actor_id,
         coalesce(p.display_name, '家人') as actor_display_name,
         c.event_count, c.occurred_at
    from claimed c
    left join public.profiles p on p.id = c.actor_id;
$$;

revoke execute on function public.claim_notification_events(integer) from public, anon;

comment on function public.claim_notification_events(integer) is
  'LS-172——push-dispatch Edge Function 專用的取件函式（service_role-only，
  SECURITY DEFINER）。先標記 sent_at = now()（冪等鎖）再回傳，即使呼叫端之後送出
  失敗也不回滾——寧可漏送不重送，見 docs/API.md 「Edge Functions」push-dispatch
  段。FOR UPDATE SKIP LOCKED 保證多個並發呼叫互不重疊。p_limit 夾在 [1, 500]。';

-- ---------------------------------------------------------------------------
-- 2. notification_recipients(p_event_ids)：對象判定＋device_tokens 展開
--
-- **LS-172 R2（merge-reviewer m1）改成批次簽章**：原本是 `notification_recipients
-- (p_event_id uuid)`，逐事件呼叫一次；push-dispatch 的 handler.ts 一次要處理一整批
-- （最多 batchLimit 筆）claimed 事件，逐事件各打一次這支 RPC 是不必要的 round
-- trip。這裡直接改簽章成 `p_event_ids uuid[]`、回傳多帶一欄 `event_id`（呼叫端用
-- 這欄把收件人列分回各自所屬的事件），不是新增一支重載——這支函式在本票落地前從未
-- 併入任何分支，唯一呼叫方是本票自己的 handler.ts／SQL 測試（同一個 PR 內一併改
-- 掉），沒有其他外部呼叫方需要相容舊簽章，保留一支沒人用的舊簽章只是累贅（Rule 2
-- 簡單優先）。因為是同一支 migration 檔的內部修改（尚未部署、尚未併入
-- origin/development），直接改這一段，不是另開一張 migration 疊代（migration
-- 不可變的保護只適用於已併入 base 的檔案，見 migration-immutable-check.sh）。
--
-- 對象＝該事件所屬家庭的成員，扣掉：
--   a) actor_id 本人（自己觸發的事件不通知自己）——`actor_id` 可能是 NULL（見上方
--      第 1 段說明），`user_id IS DISTINCT FROM ne.actor_id` 在這種情況下對所有
--      成員都成立（沒有人要被排除），語意正確。
--   b) 封鎖了 actor 的成員——`blocked_users` 是單向、限同家庭（`(family_id,
--      blocker_id, blocked_id)`，見 `20260903091317_report_block_rpc.sql`）：
--      `blocker_id = 該成員, blocked_id = actor_id, family_id = 該事件的家庭`
--      存在即排除，語意對齊既有的 `private.blocked_pairs()`（「我封鎖的人，我看
--      不到他的東西」——這裡是「我封鎖的人做的事，我不想被通知」，同一個方向）。
--      `actor_id` 是 NULL 時這個 NOT EXISTS 天生不會排除任何人（`blocked_id`
--      沒有辦法等於 NULL），與 (a) 同樣的防禦性推論一致。
--   c) 沒有任何 `device_tokens` 的成員——用 `JOIN`（不是 `LEFT JOIN`）自然排除，
--      同一個成員有多支裝置（多筆 `device_tokens`）會展開成多列，呼叫端（Edge
--      Function）逐列發送——這是刻意的：`token` 才是 APNs 呼叫的實際單位，不是
--      `user_id`。
--
-- `ne.id = any(p_event_ids)`：`p_event_ids` 為 NULL 或空陣列時這個條件對所有列都
-- 不成立（`= any('{}')` 恆假、`= any(NULL)` 恆為 NULL），回傳 0 列，不報錯——呼叫端
-- （handler.ts）永遠是拿一批非空的 claimed 事件 id 進來，這裡的空輸入行為只是
-- 防禦性的自然結果，不是特別為它寫的分支。
--
-- SECURITY DEFINER（同上方第 1 段的理由）：內部 JOIN 的三張表
-- （`family_members`／`device_tokens`／`blocked_users`）對 `service_role` 都沒有
-- 直接的 table grant（同 `notification_events` 的既有教訓，見檔頭第 4 段），
-- SECURITY DEFINER 讓函式以 postgres（表擁有者）身分執行，不需要額外逐表授權，
-- 也順帶繞過這三張表原本只對 `authenticated` 開放的 RLS policy（`service_role`
-- 呼叫的場景本來就不該受這些以「我是不是這個家庭成員」為前提的 policy 限制）。
-- `LANGUAGE SQL`（比照 `get_reaction_counts`／`private.blocked_pairs()` 的既有
-- 慣例）：單一靜態聚合查詢，沒有游標／OR 分支，不受 LS-48 F1 的 inline 限制影響。
-- ---------------------------------------------------------------------------

drop function if exists public.notification_recipients(uuid);

create or replace function public.notification_recipients(p_event_ids uuid[])
returns table (
  event_id uuid,
  user_id uuid,
  token text,
  platform public.device_platform
)
language sql
stable
security definer
set search_path = ''
as $$
  select ne.id as event_id, fm.user_id, dt.token, dt.platform
    from public.notification_events ne
    join public.family_members fm on fm.family_id = ne.family_id
    join public.device_tokens dt on dt.user_id = fm.user_id
   where ne.id = any(p_event_ids)
     and fm.user_id is distinct from ne.actor_id
     and not exists (
       select 1
         from public.blocked_users bu
        where bu.family_id = ne.family_id
          and bu.blocker_id = fm.user_id
          and bu.blocked_id = ne.actor_id
     );
$$;

revoke execute on function public.notification_recipients(uuid[]) from public, anon;

comment on function public.notification_recipients(uuid[]) is
  'LS-172（R2 改批次簽章）——push-dispatch Edge Function 專用的對象判定函式
  （service_role-only，SECURITY DEFINER）。一次吃一批 event_id，回傳每個事件所屬
  家庭成員（扣 actor 本人、扣封鎖 actor 的成員、扣沒有裝置 token 的成員）× 其全部
  device_tokens 的展開列，每列帶 event_id 供呼叫端分組——一個成員多支裝置會有多列，
  呼叫端逐列（逐 token）發送。event_id 不存在或事件的 family_id 沒有任何符合條件的
  成員時，該 event_id 對應的列就是 0 列，不報錯（同 get_my_join_request() 既有的
  「0 列＝空結果」慣例）。';

-- ---------------------------------------------------------------------------
-- 3. device_tokens：補 service_role 的 SELECT(token)／DELETE grant（失效 token
--    清除，見檔頭第 4 段——`select (token)` 是本機實測補上的必要欄位，不是裝飾）
-- ---------------------------------------------------------------------------

grant select (token), delete on public.device_tokens to service_role;
