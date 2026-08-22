-- 併發場景「兩個 owner 同時被移除」的 session 1（DELETE 路徑，與降級是不同的 trigger）。

\set ON_ERROR_STOP on

begin;

delete from public.family_members
 where family_id = 'fd000000-0000-4000-8000-000000000001'
   and user_id = 'd0000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：owner 1 移除已 commit'
