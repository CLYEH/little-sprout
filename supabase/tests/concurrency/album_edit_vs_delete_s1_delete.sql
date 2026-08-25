-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先用 set_album_deleted 軟刪，
-- 故意壓住 3 秒不 commit。
--
-- 方向 A（編輯先動）測不到 set_album_deleted 尾端那句 UPDATE 自己的鎖：先動的那一邊
-- 反正會在自己的 UPDATE 上取得列鎖，後動的一邊只要有鎖就會排隊。要讓
-- set_album_deleted 的寫入成為「先動」的那一個，才能驗到反方向的序列化——同
-- approve_reject_race／diary_edit_vs_delete 的兩個方向缺一不可（mutation test 的
-- 教訓：只跑單一方向，先動的那邊反正會在自己的 UPDATE 上取鎖，測不出後動那邊的
-- 寫入有沒有真的被序列化）。
--
-- run.sh 的 race_case 在每個方向開始前都會重跑一次 album_edit_vs_delete_setup.sql，
-- 所以這裡不必假設相簿處於哪個既有狀態。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_album_deleted('49000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
