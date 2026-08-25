-- 併發場景（方向 A：編輯先動）的 session 1：member 編輯孩子檔案，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2（owner 用 set_child_deleted 軟刪）的窗口：update_child 這句
-- `update ...` 本身（不論前面的讀取用不用 `for update`）就會對命中的列取得排他列鎖
-- 直到 commit，這是 Postgres 對任何 UPDATE 的通用行為——session 2 因此保證要等這筆
-- 交易 commit 才能繼續，「編輯先動」這個時序才成立。R1（merge-reviewer PR #95 review
-- M1）訂正：這不是「update_child 有沒有寫 `for update`」這句特定語法的功勞，四種
-- mutation 實測過，拿掉 update_child 的 `for update` 在這個方向仍然維持阻塞（見
-- `children_edit_vs_delete_s2_delete.sql` 檔頭的完整說明）——`for update` 真正的
-- 回歸覆蓋在方向 B（`children_edit_vs_delete_s2_update.sql`），不是這裡。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.update_child(
  '29000000-0000-4000-8000-000000000001', '編輯先動的新名字', date '2025-01-01', null);

select pg_sleep(3);

commit;

\echo 'S1：member 的編輯已 commit'
