-- LS-172 R2 i5 情境一，session 2：在 session 1 還沒 commit 時搶剩下的 5 筆。
--
-- 等 0.5 秒讓 session 1 的 claim UPDATE 先跑完並鎖住它那 5 筆（不需要等 session 1
-- commit，只要它的 UPDATE 已經鎖住列）——這段期間 session 1 仍在 pg_sleep(2) 內，
-- 交易尚未結束，鎖仍然持有。

\set ON_ERROR_STOP on

begin;
set local role service_role;

-- LS-96 池項 8519d8a4 第 2 條（merge-review R2-i2）：光看「S1／S2 claim 到的
-- 集合不重疊」這個最終狀態，測不出 SKIP LOCKED 本身要保護的「不阻塞」性質——
-- reviewer 實測過拿掉 SKIP LOCKED（改成單純 FOR UPDATE）之後，S2 一樣會拿到
-- 不重疊的 5 筆，只是代價是被 S1 卡住等到它 commit 為止（S1 持有交易 2 秒）。
-- 這裡額外記下 S2 呼叫 claim_notification_events() 本身的耗時：SKIP LOCKED
-- 正確運作時應該是幾毫秒等級（單純跳過已鎖的列，不等待）；若被拿掉，S2 在
-- t=0.5s 開始呼叫，會被卡到 S1 於 t≈2.0s commit 才能繼續，耗時會在 1 秒以上
-- （驗證見下方 verify.sql 的閾值與其理由）。
do $$
declare
  v_n int;
  v_before timestamptz;
  v_after timestamptz;
  v_duration_ms numeric;
begin
  perform pg_sleep(0.5);
  v_before := clock_timestamp();
  insert into public.ls172_claim_race_capture (session, event_id)
  select 's2', id from public.claim_notification_events(5);
  get diagnostics v_n = row_count;
  v_after := clock_timestamp();
  v_duration_ms := extract(epoch from (v_after - v_before)) * 1000;
  update public.ls172_claim_race_capture
     set claim_duration_ms = v_duration_ms
   where session = 's2';
  if v_n <> 5 then
    raise exception 'S2 FAIL：應該剛好 claim 到剩下的 5 筆，實際 %（若是 0 筆，可能是 SKIP LOCKED 沒有正確跳過 S1 鎖住的列，反而被卡住等待）', v_n;
  end if;
  raise notice 'S2：已 claim 5 筆（S1 鎖住的另外 5 筆之外的部分），呼叫耗時 % ms', round(v_duration_ms, 1);
end;
$$;

commit;

\echo 'S2 done'
