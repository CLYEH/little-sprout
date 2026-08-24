-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先軟刪，故意壓住 3 秒不 commit。
--
-- 方向 A（編輯先動）測不到 set_diary_deleted 自己那把 `for update`：先動的那一邊反正
-- 會在自己的 UPDATE 上取得列鎖，後動的一邊只要有鎖就會排隊。要讓 set_diary_deleted
-- 的鎖成為唯一的防線，必須讓「軟刪」當先動的那一個——這是這個方向存在的理由，
-- 同 approve_reject_race 的兩個方向缺一不可（mutation test 的教訓：只跑單一方向，
-- 拿掉其中一支 RPC 的鎖測試仍然是綠的，因為先動的那邊反正會在自己的 UPDATE 上取鎖）。
--
-- run.sh 的 race_case 在每個方向開始前都會重跑一次 diary_edit_vs_delete_setup.sql，
-- 所以這裡不必假設日記處於哪個既有狀態。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"g0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_diary_deleted('5g000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
