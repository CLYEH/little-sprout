-- LS-90 併發場景「兩連線同時 create_invite」的 session 1：owner 產碼。
--
-- 與 session 2 是同一個 owner、同一個家庭、同時呼叫同一支 RPC——這正是併發測試要
-- 覆蓋的情境（owner 在自己的 app 上連點兩下，或用兩台裝置同時打開邀請畫面）。
-- 兩邊各自的結果寫進本檔／s2.sql 的 psql 輸出（run.sh 的 race_case 會存檔），
-- 最終狀態由 invite_create_race_verify.sql 對 invites 表斷言。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"ec000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.create_invite('9a000000-0000-4000-8000-000000000001', 'member',
                             now() + interval '7 days', 3) as code;

commit;

\echo 'S1：create_invite 已 commit'
