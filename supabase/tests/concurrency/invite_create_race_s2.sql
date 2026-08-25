-- LS-90 併發場景「兩連線同時 create_invite」的 session 2：owner 產碼（與 s1 對稱）。
-- 說明見 invite_create_race_s1.sql 檔頭；run.sh 用 run_sql_bg 把 s1、s2 兩個真的
-- 並行的 psql 進程一起丟出去再 wait，時間上是重疊的，不需要額外的 pg_sleep 對齊
-- ——這個場景要驗的不是「誰卡住誰」（那是 join_race 在驗的），而是「兩邊同時執行
-- 這支 RPC 不會互相干擾」，兩邊各自獨立跑到底即可。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"ec000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.create_invite('9a000000-0000-4000-8000-000000000001', 'viewer',
                             now() + interval '7 days', 3) as code;

commit;

\echo 'S2：create_invite 已 commit'
