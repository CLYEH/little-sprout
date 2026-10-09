-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先用 set_album_deleted 軟刪，
-- 故意壓住 3 秒不 commit。
--
-- 方向 A（編輯先動）測不到 set_album_deleted 尾端那句 UPDATE 自己的鎖：先動的那一邊
-- 反正會在自己的 UPDATE 上取得列鎖，後動的一邊只要有鎖就會排隊。要讓
-- set_album_deleted 的寫入成為「先動」的那一個，才能驗到反方向的序列化——同
-- approve_reject_race／diary_edit_vs_delete 的兩個方向缺一不可。本方向驗的是**後動的
-- 直接編輯排隊、兩邊寫入都落地**。
--
-- 更正（LS-435）：這個方向並不讓 set_album_deleted 開頭那把 `for update` 成為唯一防線
-- ——軟刪交易自己的 UPDATE 已經鎖列，拿掉那把 `for update`，本方向與方向 A 照樣全綠
-- （LS-435 mutation 實測）。那把鎖的鎖強度由 album_edit_vs_delete_s1_keyshare.sql／
-- _s2_keyshare_delete.sql 的 FOR KEY SHARE 探針驗（拿掉就紅）。
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
