-- LS-195 — 檢舉事件推播只發給家庭 Owner
--
-- 來源：使用者 2026-09-05 裁決（原話「檢舉事件的推播通知『只有 Owner』」），銷 LS-96 池項
-- `12e20e0c`。`20260903091317_report_block_rpc.sql:736`（第 8 段）落地 kind='report' 的
-- notification_events 寫入時就已經在檔頭標明「已知後續工作：Edge Function 送出時需要對
-- kind='report' 特殊處理——只通知家庭 owner，不像其餘四種 kind 廣播給全家庭成員（§10-B：
-- 檢舉內容本身只有 owner 讀得到，見 content_reports_select policy）」，留給 LS-22（本票）
-- 補上那個判斷本身。
--
-- 本票只動一件事：`public.notification_recipients(uuid[])` 的 WHERE 子句多加一個條件，
-- 其餘全部逐字沿用現行定義（最新版本在 `20260904212530_suspension_and_registrations.sql`
-- 第 7 段——含 LS-172 的批次簽章／event_id 分組、LS-58 的封鎖排除、LS-172 R2 的 actor 本人
-- 排除、LS-172 第 1 段落地的停權排除）：`report` 這個 kind 的收件人再收窄一次，只留
-- `family_members.role = 'owner'`；其餘四種 kind（comment／reaction／diary／album／media）
-- 完全不受影響，行為與加這一票之前逐位元相同。
--
-- 為什麼在 SQL 面做、不是 push-dispatch 的 handler.ts 事後過濾對象：handler.ts 完全不知道
-- 每個收件人在家庭裡的角色（`notification_recipients()` 回傳的欄位裡本來就沒有 role），
-- 硬要在 TS 端做這個判斷得多一次查詢或多回傳一欄，徒增一個「SQL 判過一次、TS 又判一次」的
-- 雙重真相來源；SQL 面收斂在單一函式、單一 WHERE 子句就是唯一的把關點，符合本 repo
-- push-dispatch 契約一貫的分工（SQL 面決定「誰」、handler.ts 只決定「怎麼發」，見
-- docs/API.md §10 push-dispatch 段）。
--
-- CREATE OR REPLACE FUNCTION 對既有函式改本體（B4，migration-breaking-check.sh）＝
-- BREAKING：呼叫端（push-dispatch handler.ts）看到的收件人集合變窄了。PR body 已附
-- BREAKING: 段，docs/API.md §10 同 PR 補一列。函式簽章（參數／回傳型別）完全不變，
-- §9 機械對帳清單的 RPC 清單不需要跟著改。

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
    join public.profiles pr on pr.id = fm.user_id
    join public.device_tokens dt on dt.user_id = fm.user_id
   where ne.id = any(p_event_ids)
     and fm.user_id is distinct from ne.actor_id
     and pr.suspended_at is null
     and (ne.kind <> 'report' or fm.role = 'owner')
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
  'LS-172（R2 改批次簽章）／LS-195（kind=report 只留 owner）——push-dispatch Edge Function
  專用的對象判定函式（service_role-only，SECURITY DEFINER）。一次吃一批 event_id，回傳每個
  事件所屬家庭成員（扣 actor 本人、扣停權使用者、扣封鎖 actor 的成員、扣沒有裝置 token 的
  成員；kind=''report'' 額外只留 family_members.role=''owner''）× 其全部 device_tokens 的
  展開列，每列帶 event_id 供呼叫端分組，一個成員多支裝置會有多列。';
