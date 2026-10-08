-- 併發場景（軟刪先動）的 session 1：owner 先呼叫 delete_growth_record，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2（作者編輯）的窗口：owner 的軟刪持有這筆紀錄的列鎖，作者的
-- upsert_growth_record 必須排隊，等軟刪 commit 之後才在最新列版本上判斷。
--
-- 注意這組守不到 delete_growth_record 的 `select … for update`：軟刪交易自己的 UPDATE 也會
-- 取得同一列的列鎖並持有到 commit，拿掉 for update 這組照樣綠（LS-419 實測）。那把鎖由
-- growth_record_delete_vs_edit_s1_keyshare.sql／_s2_delete.sql 這組鎖強度探針守。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"75000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.delete_growth_record('77000000-0000-4000-8000-000000000001');

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
