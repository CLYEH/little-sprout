-- 併發場景「兩個 owner 同時被降級」的 session 1。
--
-- 開交易 → 降級 owner 1 → 故意壓住不 commit 3 秒 → commit。
-- 這 3 秒就是 session 2 的窗口：不變量若只讀不鎖，session 2 會在這段時間內
-- 看到「owner 1 還是 owner」而放行自己的降級，兩邊都 commit 之後家庭剩 0 位 owner。

\set ON_ERROR_STOP on

begin;

update public.family_members set role = 'member'
 where family_id = 'fd000000-0000-4000-8000-000000000001'
   and user_id = 'd0000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：owner 1 降級已 commit'
