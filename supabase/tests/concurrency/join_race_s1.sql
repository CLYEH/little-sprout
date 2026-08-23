-- 併發場景一的 session 1：申請人甲用掉最後一個名額，故意壓住 3 秒不 commit。
--
-- 這 3 秒就是 session 2 的窗口：request_join 若沒有 `for no key update` 鎖住 invites 那一列，
-- session 2 會在這段時間內讀到 used_count = 0（甲的加一還沒 commit）而放行自己的申請。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"ea000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;

select status, request_id is not null as has_id from public.request_join('RACE2345');

select pg_sleep(3);

commit;

\echo 'S1：甲的申請已 commit（用掉最後一個名額）'
