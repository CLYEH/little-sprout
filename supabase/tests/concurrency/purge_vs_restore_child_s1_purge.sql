-- Session 1：purge_expired() 先動，故意壓住 3 秒不 commit（比照
-- children_edit_vs_delete_s1_delete.sql 的手法：DELETE 對命中的列取得排他列鎖直到
-- commit，這是 Postgres 對任何 DELETE 的通用行為，不是 purge_expired() 內部特別加了
-- 什麼鎖）。以 postgres 身分呼叫（比照 pg_cron／service_role 實際呼叫的執行身分，見
-- migration 檔頭「權限」段落），不需要 set local role。
--
-- p_now 用固定字面值，必須與 setup 裡寫死的 deleted_at 對齊（p_now - 31 天）。

\set ON_ERROR_STOP on

begin;

select private.purge_expired(timestamptz '2026-09-03 00:00:00+00');

select pg_sleep(3);

commit;

\echo 'S1：purge_expired() 已 commit（競態孩子已被硬刪）'
