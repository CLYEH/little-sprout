-- 併發場景（LS-57：owner 軟刪先動）的 session 1：owner 軟刪這篇日記，
-- 故意壓住 3 秒不 commit。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"d1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_diary_deleted('57000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit（deleted_by 應該是 owner）'
