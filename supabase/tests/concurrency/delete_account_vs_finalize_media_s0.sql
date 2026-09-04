-- LS-155 R2 併發場景「media 軟刪 vs finalize_account_deletion」的 session 0。
--
-- 純粹用來撐開時序視窗（reviewer 的原始三連線設計，見 setup 檔頭）：鎖住家 A 的
-- UO 成員列 9 秒——這不是死鎖本身需要的條件（自然競態本來就存在，見 setup 檔頭
-- 「S0 只是把窗口撐大」），而是讓這個視窗大到能在 CI 與本機都穩定重現，不必依賴
-- S1／S2 兩個 pg_sleep offset 精準卡進一個原生只有毫秒級的窗口。

\set ON_ERROR_STOP on

begin;

select user_id from public.family_members
 where family_id = 'e8000000-0000-4000-8000-000000000002'
   and user_id = 'e8000000-0000-4000-8000-000000000011'
 for update;

select pg_sleep(9);

rollback;

\echo 'S0：已釋放家 A 的 UO 成員列鎖'
