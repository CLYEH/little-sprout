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
-- 由 private.derive_display_name(meta, email) 統一推導並正規化（R1 F1 修正）——
-- 依序取 full_name、name、email 帳號部分，每個候選都先 btrim 再截斷到 50 字
-- （`left`），空字串／全空白視同沒有該候選（`nullif(..., '')` 後才落到下一個
-- coalesce 分支）；三個候選全部落空時（例如 email 也是 NULL）最終保底 '新成員'，
-- 確保一定通過 profiles_display_name_check（`between 1 and 50`），不讓超長／空白
-- 顯示名把整個 auth.users 的 INSERT 交易 rollback。avatar_url 同樣用
-- nullif(btrim(...), '') 把空字串正規化成 NULL（profiles.avatar_url 本來就允許
-- NULL）。on conflict (id) do nothing：呼叫端（LS-107 的 ensureProfileExists，或
-- 既有 supabase/tests fixture 的慣例寫法）之後仍可能冪等地再 insert 一次，不該讓
-- 它撞 23505。
--
-- RLS：不需要改。profiles_select／profiles_insert／profiles_update 三條 policy
-- （20260822120200_rls_policies.sql）維持現狀不動——trigger 函式寫入
-- public.profiles 之所以不被 RLS 擋下，理由是 (a) 執行身分 postgres 有 BYPASSRLS
-- 屬性（`postgres` 在本機／CI／正式站都不是 superuser，`rolsuper = false`；靠的
-- 是 BYPASSRLS，不是 superuser 豁免），且 (b) public.profiles 的 owner 正是
-- postgres、未設 FORCE ROW LEVEL SECURITY。這點很關鍵：trigger 觸發當下沒有登入
-- 中的 JWT，(select auth.uid()) 只會是 NULL，若哪天這條路徑換成非 owner 的執行
-- 身分、或對 profiles 開了 FORCE RLS，profiles_insert policy
-- （with check id = auth.uid()）會直接全部擋下、整個 auth.users 的 INSERT
-- 交易跟著失敗。
--
-- 權限：比照既有 private.* SECURITY DEFINER 函式慣例——20260822120300_harden_
-- default_privileges.sql 已經把「未來新建函式」的 PUBLIC 預設 EXECUTE 全域收回，
-- 這支新函式不需要再手動 revoke；supabase/tests/60_default_privileges.sql §2 的
-- schema private 通掃（允許清單機制）也會自動涵蓋它，不必手動加名單——只有 trigger
-- 會呼叫它，authenticated／anon 都不需要、也不應該有 EXECUTE。

create or replace function private.derive_display_name(meta jsonb, email text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select coalesce(
    nullif(left(btrim(meta ->> 'full_name'), 50), ''),
    nullif(left(btrim(meta ->> 'name'), 50), ''),
    nullif(left(btrim(split_part(coalesce(email, ''), '@', 1)), 50), ''),
    '新成員'
  );
$$;

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
    private.derive_display_name(new.raw_user_meta_data, new.email),
    nullif(btrim(new.raw_user_meta_data ->> 'avatar_url'), '')
  )
  on conflict (id) do nothing;
  return null;
end;
$$;

-- orchestrator 訂正（不等 DESTRUCTIVE-APPROVED）：原本這裡是 `drop trigger if
-- exists` 再 `create trigger`，會被 migration-breaking-check.sh 判成 DESTRUCTIVE
-- （不分是否 IF EXISTS），需要使用者本人在 PR body 蓋 DESTRUCTIVE-APPROVED 才能過
-- CI。改成純 DO 區塊守衛：trigger 已存在就跳過，不存在才建——沒有 DROP，一樣冪等
-- （函式本身已是 create or replace，trigger 定義若之後要改，本來就得靠新 migration
-- 明確處理，不是這裡該管的事）。
do $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgname = 'on_auth_user_created' and tgrelid = 'auth.users'::regclass
  ) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function private.handle_new_auth_user();
  end if;
end;
$$;

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
  private.derive_display_name(u.raw_user_meta_data, u.email),
  nullif(btrim(u.raw_user_meta_data ->> 'avatar_url'), '')
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;
