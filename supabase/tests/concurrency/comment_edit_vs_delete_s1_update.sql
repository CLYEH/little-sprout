-- 併發場景（方向 A：作者的直接 UPDATE 先動）的 session 1：作者直接 UPDATE
-- body，故意壓住 3 秒不 commit。結構同 album_edit_vs_delete_s1_update.sql。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

update public.comments set body = '編輯先動的新留言'
 where id = '69000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：作者的直接 UPDATE 已 commit'
