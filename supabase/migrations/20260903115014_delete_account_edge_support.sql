-- LS-151（LS-24 拆票之二）— Edge Function delete-account 的資料面支援：
--   1. profiles.deletion_requested_at 開放 service_role SELECT（Edge Function 用
--      service_role 檢查這一欄，見 docs/API.md §「Edge Functions」）。
--   2. 過渡期擋寫（票文「範圍」第 2 點，票文明說「優先 (a)」）：deletion_requested_at
--      非 NULL 時，擋下 create_family／approve_join／上傳／建立內容四類寫入，讓
--      「過渡期又成為某個家庭唯一 owner」這個 R1 i1 指出的情境從源頭不可能發生——
--      不是等 Edge Function 真的刪 auth.users 時才補救（票文選項 b），是讓這個
--      使用者從 delete_my_account() 回傳的那一刻起，直接沒有任何路徑能再取得
--      family_members 的任何一列（見下方第 2 段）。
--
-- 背景（LS-143 merge-review R1 i1，`d9cce6a4`，實測確認）：delete_my_account() 回傳
-- 成功之後、Edge Function 真正刪掉 auth.users 之前，這個帳號仍是完全可用的登入身份
-- ——deletion_requested_at 目前不被任何既有 RLS policy 或 grant 讀取。若使用者在這個
-- 窗口內又成為某個家庭的唯一 owner，Edge Function 呼叫 service_role 執行
-- `delete from auth.users` 時，cascade 到 family_members 的刪除會被既有的
-- private.enforce_family_has_owner() trigger 擋下（LS001），該次刪除會失敗
-- （docs/API.md §4 delete_my_account 已明文；本 migration 是那句話承諾的落地）。
--
-- ---------------------------------------------------------------------------
-- 為什麼選 (a) 不選 (b)：delete_my_account() 的三種結果（見
-- 20260903084231_delete_account.sql）回傳之後，呼叫者必然：
--   - 情況 1（唯一 owner 且家庭還有其他成員）→ 整個呼叫被拒絕，deletion_requested_at
--     根本不會被標記，不進入過渡期，不適用本 migration。
--   - 情況 2（唯一成員）→ 家庭連同 family_members 一併被 DELETE FROM families cascade
--     掉，呼叫者在這個家庭已經沒有 family_members 列。
--   - 情況 3（其餘家庭）→ 最後一句 `DELETE FROM family_members WHERE user_id = v_uid`
--     涵蓋呼叫者在情況 2 之外的每一個家庭，呼叫者離開全部家庭。
-- 三種結果收斂到同一個事實：delete_my_account() 成功回傳的那一刻，呼叫者在
-- family_members 裡已經沒有任何一列——也就沒有任何一個家庭的 owner／member／viewer
-- 身分。過渡期唯一能讓他「又成為唯一 owner」的路徑，只有重新取得一列
-- family_members（建立新家庭時的自動 owner INSERT，或被邀請碼核准加入）。把這一張
-- 表的 INSERT 直接擋掉，「過渡期又成為唯一 owner」這個情境就從資料面直接消失，
-- 不需要 Edge Function 在刪除前先重跑一次清理去補救一個原本就不該發生的狀態
-- （選項 (b) 等於是在下游收拾一個上游可以直接不讓它發生的爛攤子）。
--
-- 為什麼不能只靠 RLS policy：family_members 唯一的寫入路徑是兩支 SECURITY DEFINER
-- 函式（private.add_creator_as_owner()、public.approve_join()），兩者都以表擁有者
-- （postgres）身分執行、天生繞過 RLS——family_members_insert policy 早在 LS-33 就已經
-- 是 `with check (false)`（20260823010000_join_approval.sql），對這兩支函式完全無感，
-- 這正是它們必須存在的理由。真正能擋住 SECURITY DEFINER 函式寫入的只有 BEFORE INSERT
-- trigger（trigger 不受 RLS bypass 影響，任何身分的 INSERT 都會先經過它）。
--
-- 擋寫範圍（票文「create_family、approve_join、上傳、建立內容」逐項對應；不是只擋
-- 最小必要的 family_members，是把票文點名的四類寫入行為都擋掉）：
--   families        → create_family（直接 INSERT，任何登入者建立家庭的唯一路徑）
--   family_members  → 建立新家庭的自動 owner INSERT（private.add_creator_as_owner）
--                      ＋ approve_join（核准加入）
--   media           → 上傳（直接 INSERT，有上傳權者）
--   diaries         → 建立內容：create_diary_entry
--   albums          → 建立內容：直接 INSERT（owner／member）
--   children        → 建立內容：create_child
--   comments        → 建立內容：create_comment
-- 刻意不擋（規格分歧與取捨，供之後改動的人對照）：invites（create_invite）、
-- join_requests（request_join）、reactions（toggle_reaction）、device_tokens
-- （register_device_token）、diary_children／album_children（標記，不是新內容本體）
-- ——這幾張表的寫入不會讓呼叫者取得任何一列 family_members，不構成 R1 i1 指出的
-- 「又成為唯一 owner」風險；票文列出的四類（create_family／approve_join／上傳／
-- 建立內容）已逐項對應到上面七張表，繼續擴大範圍不是本票要解的問題，且會增加
-- 之後每一支新寫入 RPC 都要記得補掛 trigger 的維護負擔。
--
-- 錯誤碼 LS051（延續 LS050，同一批 LS-24 拆票，避開同時在飛的 LS-153——LS-153
-- 的 20260903110908_purge_expired.sql 沒有使用任何新的 LSnnn 自訂碼，不會撞號）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. service_role 讀 profiles.deletion_requested_at（Edge Function 用）
--
-- 比照 notification_events 的既有教訓（20260825020000_comments_reactions_notifications.sql
-- 「service_role 也要明確 grant」）：public schema 新 grant／既有表對 service_role 的
-- 存取不是平台預設會給，必須自己明確授權。profiles 從第一支 migration 起就沒有對
-- service_role 下過任何 grant（table owner 是 postgres，service_role 是不同角色）。
-- 只開 SELECT：Edge Function 只需要讀這一欄判斷是否放行，不需要寫 profiles
-- （auth.users 被 admin API 刪除後，profiles 隨既有的 on delete cascade 自動消失，
-- 不需要 Edge Function 自己 UPDATE／DELETE 這張表）。
-- ---------------------------------------------------------------------------
grant select on public.profiles to service_role;

-- ---------------------------------------------------------------------------
-- 2. 過渡期擋寫的共用 guard 函式
--
-- SECURITY DEFINER＋search_path 收斂：比照本 schema 所有 private 函式的既有慣例
-- （60_default_privileges.sql 第 9 段），且這裡確實需要讀 public.profiles（trigger
-- 若以 invoker 身分執行，讀 profiles 本身沒問題——authenticated 對 profiles 有整表
-- SELECT grant，見 20260822120000_init_schema.sql——但 definer 是本 schema 一貫寫法，
-- 不另立例外）。auth.uid() 為 NULL（沒有 JWT claims 的 session，例如 pg_cron／測試
-- 用 postgres 身分直接 INSERT 造 fixture）時直接放行——這不是「未登入者可以寫」的
-- 破口：這些表原本就各自有 RLS policy／grant 擋未登入者，這裡的 guard 只多加一層
-- 「已登入但正在刪帳號過渡期」的檢查，不取代、也不放寬既有的權限檢查。
-- 不需要登記進 60_default_privileges.sql §2 的 v_allow_fns：這是純內部用的 trigger
-- 函式，不對外開放 EXECUTE，本來就會被該段的通掃覆蓋（不開放給 authenticated／anon）。
-- ---------------------------------------------------------------------------
create or replace function private.enforce_account_not_deletion_requested()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is not null and exists (
    select 1 from public.profiles where id = v_uid and deletion_requested_at is not null
  ) then
    raise exception
      '帳號已請求刪除（過渡期間），無法再建立新資料——請等待帳號刪除完成'
      using errcode = 'LS051';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_account_not_deletion_requested() from public, anon;

comment on function private.enforce_account_not_deletion_requested() is
  'LS-151：deletion_requested_at 非 NULL 時擋下 INSERT（LS051）。掛在
  families／family_members／media／diaries／albums／children／comments 七張表的
  BEFORE INSERT，讓過渡期使用者無法再建立新資料、無法再取得任何一列
  family_members——「過渡期又成為某個家庭唯一 owner」（LS-143 merge-review R1 i1）
  因此從源頭不可能發生，Edge Function delete-account 呼叫 service_role 執行
  `delete from auth.users` 時不會再撞見 LS001。';

create trigger families_deletion_guard
  before insert on public.families
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger family_members_deletion_guard
  before insert on public.family_members
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger media_deletion_guard
  before insert on public.media
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger diaries_deletion_guard
  before insert on public.diaries
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger albums_deletion_guard
  before insert on public.albums
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger children_deletion_guard
  before insert on public.children
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger comments_deletion_guard
  before insert on public.comments
  for each row execute function private.enforce_account_not_deletion_requested();
