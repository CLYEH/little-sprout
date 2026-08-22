-- LS-15 — DB 硬化：rls_auto_enable 收權 + sequences/functions default privileges
--
-- 背景（LS-14 雲端 \ddp／security advisors 覆核發現，見該票 comment）：
--   1. security advisors WARN：public.rls_auto_enable()——Supabase 平台在專案佈建時建立、
--      支撐「自動啟用 RLS」event trigger 的 SECURITY DEFINER 函式——對 anon/authenticated
--      開放 EXECUTE，可被任何登入或未登入使用者經 /rest/v1/rpc/ 呼叫。它只是 event trigger
--      的內部支撐函式，不該有任何 API 呼叫者。
--   2. pg_default_acl 覆核：20260822120000_init_schema.sql 收斂 default privileges 時只涵蓋
--      tables，postgres 角色在 public schema 對 sequences／functions 的 default ACL 仍對
--      anon/authenticated 全開（Supabase 專案佈建時的預設，同一份風險）。
--
-- 已知限制（記錄、非本 migration 處理範圍）：supabase_admin 名下的 public default ACL
-- 同樣全開，但 postgres 身分無權更動它，且我們的 migration 一律以 postgres 身分執行、
-- 不會經由 supabase_admin 建立物件。這是 LS-14 已查明並記錄的接受風險。

-- ---------------------------------------------------------------------------
-- 1. rls_auto_enable：event trigger 的支撐函式，收回三個角色的 EXECUTE
--
-- 這支函式只存在於雲端 Supabase 專案（LS-14 advisors 實查看到它）；官方
-- `supabase` CLI 的本機開發映像（`supabase db start` 用的那份）沒有這支函式——
-- 用 guard 包起來，函式不存在時整段跳過，migration chain 才能在兩種環境都套用。
-- 沒有 guard 直接 revoke 會撞 42883（PR #17 的 CI db job 實測過：
-- run https://github.com/CLYEH/little-sprout/actions/runs/32565795483，
-- `ERROR: function public.rls_auto_enable() does not exist (SQLSTATE 42883)`）。
-- REVOKE 語法本身沒有 IF EXISTS，只能用動態 SQL 包一層條件判斷。
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. sequences 的 default privileges（前一個 migration 沒涵蓋的洞）
-- ---------------------------------------------------------------------------
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. functions 的 default privileges——採「per-RPC 顯式 grant」慣例
--
-- 這裡需要兩句、缺一不可（實測 PostgreSQL 16 才發現的必要性，不是重複）：
--
--   a) schema 範圍：把 Supabase 佈建時放進 pg_default_acl 的 anon/authenticated 那份
--      明文授權拿掉。
--   b) 不指定 schema 的全域：function 的內建預設本來就含「PUBLIC 可執行」，這份 PUBLIC
--      授權不是存在 pg_default_acl 的 schema 條目裡，schema 範圍的
--      `revoke ... from public` 對它沒有作用對象可收（實測：下了之後 pg_default_acl
--      該筆列毫無變化，新函式仍然對 PUBLIC 開放——與 rls_policies.sql 檔尾對 schema
--      private 的說明是同一件事，只是那裡在講「加不回去」，這裡是「單靠 schema 範圍
--      減不掉」）。能讓新函式不再繼承 PUBLIC 這份內建預設的，只有不指定 schema 的
--      全域寫法；因為 anon/authenticated 是 PUBLIC 的成員，只做 (a) 不做 (b)，
--      anon/authenticated 仍會經由 PUBLIC 拿到 EXECUTE（已用 60_default_privileges.sql
--      的新建 function 探針證實）。
--
--   全域寫法會連帶收斂「postgres 身分未來在任何 schema 建立的函式」，不只 public——
--   這正是「per-RPC 顯式 grant」慣例要的效果，且不影響已用個別 grant 開放的既有函式
--   （register_device_token 是既有物件的個別 ACL，與這裡收斂的「未來新函式」default ACL
--   是兩份獨立資料，回歸驗證見 supabase/tests/60_default_privileges.sql）。
--
--   全域寫法有兩個明確的副作用，記在這裡不是「順便一提」，是要讓下一個踩到的人知道
--   去哪裡查：
--     i)  未來若有 migration 以 postgres 身分安裝 extension（例如 pg_trgm／unaccent），
--         該 extension 帶來的函式一樣會落入這份全域預設——對 public/anon/authenticated
--         都不可執行。這不是本 migration 能一併處理的事：安裝 extension 的那個 migration
--         必須自己比照 register_device_token 的慣例，對它會被 app 呼叫的函式逐一
--         `grant execute ... to <角色>`。
--     ii) public 以外的 schema（含未來新增的 schema）由 postgres 身分建立的函式，
--         同樣會失去 PUBLIC 這份內建預設——連帶讓 service_role 原本「經由 PUBLIC」
--         拿到的隱式執行權一起消失。下面這句 `grant execute on functions to
--         service_role`（同樣不指定 schema）就是為了把 service_role 的預設可執行權
--         明確地釘在 global default ACL 上，不再依賴 PUBLIC baseline。
-- ---------------------------------------------------------------------------
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- 承上 (ii)：把 service_role 的預設 EXECUTE 從「PUBLIC baseline 帶來的隱式權限」
-- 改成「明確的 global default ACL 項目」，讓 public 以外的 schema 未來新函式
-- 也不會因為上面兩句 revoke 而連帶失去 service_role 的預設存取——
-- 已用 60_default_privileges.sql 的探針證實：任意 schema 新函式對 service_role
-- 仍可執行、對 anon/authenticated 仍不可執行。
alter default privileges grant execute on functions to service_role;
