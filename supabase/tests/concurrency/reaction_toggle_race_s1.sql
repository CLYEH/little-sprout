-- 雙 toggle 併發場景的 session 1：第一次呼叫 toggle_reaction（加入反應），故意在
-- commit 前壓住 3 秒——toggle_reaction 內部的 pg_advisory_xact_lock 是交易範圍鎖，
-- 只要交易還沒 commit，鎖就還握著，session 2 的第二次呼叫必須在這段時間內排隊等待。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.toggle_reaction('f6000000-0000-4000-8000-000000000001', 'album',
  '6c000000-0000-4000-8000-000000000001');

select pg_sleep(3);

commit;

\echo 'S1：第一次 toggle_reaction（加入）已 commit'
