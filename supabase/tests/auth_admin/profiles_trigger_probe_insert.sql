-- LS-110 R1 F2 — 用正式路徑角色 supabase_auth_admin（GoTrue 寫 auth.users 用的
-- 身分）插入 auth.users，讓 trigger 在真正的角色路徑下建立 profiles 列。
--
-- 96_profiles_auto_create.sql 的六段情境驗證都是以本檔案的姊妹檔案執行者（本機／
-- CI 一般是 postgres）身分跑；那六段本身沒有問題，但「postgres 身分下能跑」不等於
-- 「正式站能跑」——若函式哪天被改成 SECURITY INVOKER、owner 換人、或搬到別的
-- schema，postgres 身分（有 BYPASSRLS、是 profiles 的 owner）仍可能全綠，紅燈只會
-- 出現在正式站 GoTrue 用 supabase_auth_admin 寫入時的 500。96_ 的第 7 段已經把這幾個
-- 前提釘成結構性斷言；這裡另外用真正的角色連線重現一次，屬於實跑證據，不是
-- catalog 推論。
--
-- 只做 insert、不在這裡驗證：supabase_auth_admin 對 public.profiles 沒有任何
-- grant（正式路徑上 GoTrue 本來就不需要，也不應該讀這張表）——SELECT 驗證與清理
-- 交給姊妹檔 profiles_trigger_probe_verify.sql，用一般連線（有 profiles 的 owner
-- 權限）跑。這裡故意不包 begin/rollback：要讓資料真正 commit，交給下一步驗證。
--
-- 之所以另開目錄、不併進 96_：這裡需要換一個連線身分（supabase_auth_admin），
-- 不能用 96_ 共用的連線跑；不放在 `[0-9][0-9]_*.sql` 的命名下，不會被
-- supabase/tests/run.sh 的主迴圈誤用一般身分跑一次——由 run.sh 用
-- run_sql_as_auth_admin() 專門呼叫。

\set ON_ERROR_STOP on

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-0000000000aa', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-authadmin@ls110.test', now(), now(), '{}',
        '{"full_name": "正式路徑角色測試"}');
