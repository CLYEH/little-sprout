-- 併發場景（方向 A：編輯先動）的 session 1：作者編輯內容，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2（owner 軟刪）的窗口：update_diary_entry 若沒有 `for update`
-- 鎖住日記列，owner 會在這段時間內直接軟刪成功，跟編輯的 commit 順序不確定，
-- 「編輯先動」這個時序保證就不存在。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a8000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.update_diary_entry(
  '59000000-0000-4000-8000-000000000001', '編輯先動的新內容', current_date, null);

select pg_sleep(3);

commit;

\echo 'S1：作者的編輯已 commit'
