-- LS-172 R2 i5 情境二，session 2：在 session 1 的 claim 交易還沒 commit 時，用真正
-- 的 create_comment() RPC（跟 production 呼叫路徑一致）對同一個 target 建立一則
-- 新留言——觸發 notify_comment_created() → record_notification_event()。
--
-- **本機實測踩出的修正（重要，別再犯同一個錯）**：這裡原本預期 record_notification_
-- event() 對事件 X 的 SELECT ... FOR UPDATE 會被 S1 鎖住 X 卡住，等 S1 commit 後
-- 才能繼續（EvalPlanQual 重新檢查）——**這個預期是錯的，本機跑出來 S2 完全沒有被
-- 阻塞（僅 0.01 秒）**。原因：claim_notification_events() 的候選條件是
-- `occurred_at < now() - interval '5 minutes'`，record_notification_event() 的
-- 合併條件是 `occurred_at >= now() - interval '5 minutes'`——這兩個條件對**同一個
-- `now()` 求值**是嚴格互補、零重疊的（`<` 跟 `>=` 二分整條時間軸，任何一個瞬間
-- 只可能滿足其中一個）。事件 X 的 occurred_at 是 10 分鐘前，早就落在 claim 的候選
-- 範圍裡，但也因此**永遠不可能落在 record 的合併候選範圍裡**——record 的 SELECT
-- 在掃描階段就被 `occurred_at >= now()-5min` 這個條件過濾掉，根本不會嘗試對 X
-- 取鎖，自然無從被 S1 卡住。真正保護「不會誤合併進已經太舊的列」這個不變量的，
-- 是 occurred_at 過濾本身，不是鎖／sent_at——sent_at is null 這個條件只在「5 分鐘
-- 視窗內」才有意義，對已經過期的列從一開始就用不到。
--
-- 這裡仍然用真正並行的兩個 session（不是序列跑）驗證：即使 S1 的交易還沒 commit、
-- S2 幾乎同時對同一個 target 送出新留言，最終結果仍然正確——「併發」驗的是
-- 「這兩件事幾乎同時發生時結果依然對」，不是「一定會互相鎖住」。移除了原本錯誤
-- 假設的阻塞時間斷言，只留最終狀態驗證（見 push_dispatch_claim_vs_record_verify.sql）。

\set ON_ERROR_STOP on

do $$
declare
  v_new_comment_id uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'c1000000-0000-4000-8000-000000000012', 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 讓 session 1 的 claim 先跑完（不需要等它 commit），確保兩邊的操作真的在
  -- S1 交易仍然開著的時候重疊發生。
  perform pg_sleep(0.5);

  v_new_comment_id := public.create_comment(
    'c2000000-0000-4000-8000-000000000002', 'diary',
    'c4000000-0000-4000-8000-000000000001', 'LS172 併發測試留言'
  );

  insert into public.ls172_claim_vs_record_capture (session, claimed_id) values ('s2', v_new_comment_id);

  raise notice 'S2：留言建立完成（id=%），S1 的 claim 交易此時應該仍未 commit', v_new_comment_id;
end;
$$;

\echo 'S2 done'
