-- LS-378 併發場景（共用照片的兩篇日記同時刪除）session 1：owner 軟刪 D1，
-- 壓住 3 秒不 commit（trigger 已持有照片的 media 列鎖）。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"d3780000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_diary_deleted('53780000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：D1 軟刪已 commit'
