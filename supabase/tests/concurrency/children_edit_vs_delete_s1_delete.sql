-- 併發場景（方向 B：軟刪先動）的 session 1：owner 先軟刪，故意壓住 3 秒不 commit。
--
-- 這個方向存在的理由：兩個方向（誰先動）都要跑，同 diary_edit_vs_delete 的既有慣例
-- ——只跑單一方向，先動的那邊反正會在自己的 UPDATE 上取得列鎖，測不出「後動那一邊
-- 的初始讀取有沒有加 for update」這件事本身是否重要。這裡讓「軟刪」當先動的那一個，
-- 換 session 2（`children_edit_vs_delete_s2_update.sql`）的 update_child 當後動的
-- 那一邊——真正驗到 update_child 那把 `for update` 是否必要的是 session 2 那份檔案
-- （拿掉它會讓 session 2 讀到軟刪前的舊快照、放行一次不該成立的編輯），不是這裡。
--
-- R1（merge-reviewer PR #95 review M1）訂正：本檔開頭原本宣稱「這個方向存在是為了
-- 測 set_child_deleted 自己那把 for update」——四種 mutation 實測過，拿掉
-- set_child_deleted 的 `for update` 之後，這個方向的兩條斷言仍然全綠，證明不了那句
-- 話。set_child_deleted 開頭那句 `for update` 是讀 family_id 做授權判斷的 TOCTOU
-- 防線（LS-52 定下的規則），是防禦性正確作法，但不是這組併發測試的必要條件——
-- 阻塞的來源、以及被阻塞方最終拿到什麼結果，都是由**後動那一邊**（本方向是
-- update_child）的行為決定，不是先動那一邊有沒有加鎖。
--
-- run.sh 的 race_case 在每個方向開始前都會重跑一次 children_edit_vs_delete_setup.sql，
-- 所以這裡不必假設孩子檔案處於哪個既有狀態。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_child_deleted('29000000-0000-4000-8000-000000000001', true);

select pg_sleep(3);

commit;

\echo 'S1：owner 的軟刪已 commit'
