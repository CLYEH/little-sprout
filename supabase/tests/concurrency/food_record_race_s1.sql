-- LS-325 併發場景 session 1：第一次記錄 banana，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2 的窗口：upsert_child_food_record 靠 partial unique index
-- 當 ON CONFLICT 的仲裁目標——若沒有這個機制，S2 會在這段時間內判斷「還沒有
-- 紀錄」而各自 INSERT，撞 23505（見 migration 檔頭第 0 段 a）。有這個機制時，
-- S2 的 INSERT 會在 Postgres 內部偵測到衝突後等待 S1 這筆交易結束才判定，見
-- food_record_race_s2.sql 檔頭。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"72000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.upsert_child_food_record(
  '73000000-0000-4000-8000-000000000001', 'banana', date '2026-01-01', null, 'S1 記錄', 'liked');

select pg_sleep(3);

commit;

\echo 'S1：banana 已第一次記錄並 commit'
