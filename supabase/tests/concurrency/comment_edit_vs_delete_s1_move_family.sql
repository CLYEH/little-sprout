-- 併發場景（方向 C：作者搬家先動）的 session 1：作者把自己的留言直接 UPDATE 搬到
-- 自己也是 owner 的另一個家庭（f9），故意壓住 3 秒不 commit。理由同
-- album_edit_vs_delete_s1_move_family.sql（不重複展開）。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

update public.comments set family_id = 'f9000000-0000-4000-8000-000000000001'
 where id = '69000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：作者的搬家 UPDATE 已 commit（留言現在屬於 f9）'
