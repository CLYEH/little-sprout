-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先用 set_comment_deleted 軟刪，
-- 故意壓住 3 秒不 commit。理由同 album_edit_vs_delete_s1_delete.sql。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_comment_deleted('69000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
