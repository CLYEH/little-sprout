-- 併發場景二的 session 1：爸爸核准，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2（媽媽按拒絕）的窗口：approve_join／reject_join 若沒有 `for update`
-- 鎖住申請列，媽媽會在這段時間內讀到 status 還是 pending 而放行自己的拒絕，
-- 最後變成「申請被標記為 rejected，成員卻已經寫進 family_members」——
-- 「拒絕後無殘留權限」這條驗收條件就是在這個時序下破掉的。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"eb000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.approve_join('9f000000-0000-4000-8000-000000000001');

select pg_sleep(3);

commit;

\echo 'S1：爸爸的核准已 commit'
