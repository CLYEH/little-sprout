-- 併發場景（方向 A：作者的直接 UPDATE 先動）的 session 1：作者直接 UPDATE 標題，
-- 故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2（owner 用 set_album_deleted 軟刪）的窗口。albums 的內容編輯
-- 走**直接 UPDATE**（不是 RPC，見 albums_update policy），任何 UPDATE 本身就會對
-- 命中的列取隱含的列鎖——這一點不需要、也不能額外加 `for update`。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

update public.albums set title = '編輯先動的新標題'
 where id = '49000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：作者的直接 UPDATE 已 commit'
