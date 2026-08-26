-- LS-110 — profiles 自動建立：auth.users insert trigger ＋ 既有缺列回填
--
-- 背景（LS-107 實作 Owner 路徑時發現，見 LS-110 票文）：docs/API.md 舊版寫「登入流程
-- 要 insert 一列 profiles」，但 repo 裡從沒有任何登入路徑真的做這件事（Apple／Google／
-- Email OTP 皆無）；families／invites／join_requests 的 RLS 與 RPC 全部依賴 profiles
-- 存在。ios-dev 在 createFamily 前補了窄範圍 ensureProfileExists（PR #170）解阻塞，
-- 但 LS-108（加入路徑：request_join／list_join_requests 讀 display_name／avatar）
-- 會再撞同一缺口。本票把「profiles 一定存在」的責任收回後端，一勞永逸——client 不再
-- 需要、也不再是登入路徑的必要條件。
--
-- 修法：auth.users 的 AFTER INSERT trigger 自動建立對應 profiles 列；display_name
-- 依序取 raw_user_meta_data->>'full_name'、->>'name'、email 帳號部分（split_part）；
-- avatar_url 取 raw_user_meta_data->>'avatar_url'（沒有就是 NULL，profiles.avatar_url
-- 本來就允許 NULL）。on conflict (id) do nothing：呼叫端（LS-107 的
-- ensureProfileExists，或既有 supabase/tests fixture 的慣例寫法）之後仍可能冪等地
-- 再 insert 一次，不該讓它撞 23505。
--
-- RLS：不需要改。profiles_select／profiles_insert／profiles_update 三條 policy
-- （20260822120200_rls_policies.sql）維持現狀不動——trigger 函式建立時的目前角色是
-- postgres（本機／CI 套用 migration 的執行身分），postgres 是 superuser，RLS 對
-- superuser 一律不生效，不因 SECURITY DEFINER 或表 owner 而有例外。這點很關鍵：
-- trigger 觸發當下沒有登入中的 JWT，(select auth.uid()) 只會是 NULL，若這裡的 INSERT
-- 受 profiles_insert policy（with check id = auth.uid()）管制會直接全部擋下、
-- 整個 auth.users 的 INSERT 交易跟著失敗。
--
-- 權限：比照既有 private.* SECURITY DEFINER 函式慣例——20260822120300_harden_
-- default_privileges.sql 已經把「未來新建函式」的 PUBLIC 預設 EXECUTE 全域收回，
-- 這支新函式不需要再手動 revoke；supabase/tests/60_default_privileges.sql §2 的
-- schema private 通掃（允許清單機制）也會自動涵蓋它，不必手動加名單——只有 trigger
-- 會呼叫它，authenticated／anon 都不需要、也不應該有 EXECUTE。

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1)
    ),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return null;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- 回填：trigger 佈署之前就已存在、缺 profiles 列的 auth.users
-- ---------------------------------------------------------------------------
-- where not exists + on conflict (id) do nothing 雙重保險：前者是主要邏輯（避免
-- 對已有 profile 的大多數列做無謂掃描），後者純粹是跟 trigger 共用同一句慣用語、
-- 供日後若被複製到別處手動重跑時也不會因為競態或重複執行而炸——單一 migration
-- 交易內兩者不會真的衝突。
insert into public.profiles (id, display_name, avatar_url)
select
  u.id,
  coalesce(
    u.raw_user_meta_data ->> 'full_name',
    u.raw_user_meta_data ->> 'name',
    split_part(u.email, '@', 1)
  ),
  u.raw_user_meta_data ->> 'avatar_url'
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;
