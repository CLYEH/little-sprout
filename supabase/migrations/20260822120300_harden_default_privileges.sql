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
-- ---------------------------------------------------------------------------
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

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
-- ---------------------------------------------------------------------------
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
