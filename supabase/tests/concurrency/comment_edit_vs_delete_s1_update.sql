-- 併發場景（方向 A：作者的編輯先動）的 session 1：作者呼叫 update_comment 改
-- body，故意壓住 3 秒不 commit。結構同 album_edit_vs_delete_s1_update.sql。
--
-- LS-58：comments 的 UPDATE 已收斂成 RPC-only（見
-- 20260825020000_comments_reactions_notifications.sql），直接 `update public.
-- comments ...` 已被 revoke，這裡改呼叫 update_comment；update_comment 內部
-- 同樣對目標列 `for update`，鎖住的時序保證與收斂前的直接 UPDATE 一致。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.update_comment('69000000-0000-4000-8000-000000000001', '編輯先動的新留言');

select pg_sleep(3);

commit;

\echo 'S1：作者的 update_comment 已 commit'
