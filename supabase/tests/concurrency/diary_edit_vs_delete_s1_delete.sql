-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先軟刪，故意壓住 3 秒不 commit。
--
-- 方向 A（編輯先動）測不到 set_diary_deleted 自己那把 `for update`：先動的那一邊反正
-- 會在自己的 UPDATE 上取得列鎖，後動的一邊只要有鎖就會排隊。本方向讓「軟刪」當先動的
-- 那一個，驗的是**後動的編輯（update_diary_entry）排隊、解除後拿到 LS020**——這是這個
-- 方向存在的理由，同 approve_reject_race 的兩個方向缺一不可。
--
-- 更正（LS-435）：本檔原本宣稱這個方向讓 set_diary_deleted 的鎖「成為唯一的防線」，
-- 不成立——軟刪交易自己的 UPDATE 已經鎖列，拿掉 set_diary_deleted 的 `for update`，
-- 本方向與方向 A 照樣全綠（LS-435 mutation 實測）。set_diary_deleted 那把 `for update`
-- 的鎖強度由 diary_edit_vs_delete_s1_keyshare.sql／_s2_keyshare_delete.sql 的 FOR KEY
-- SHARE 探針驗（拿掉就紅）。
--
-- run.sh 的 race_case 在每個方向開始前都會重跑一次 diary_edit_vs_delete_setup.sql，
-- 所以這裡不必假設日記處於哪個既有狀態。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a9000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_diary_deleted('59000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
