-- LS-172 R2 i5 情境一，session 2：在 session 1 還沒 commit 時搶剩下的 5 筆。
--
-- 等 0.5 秒讓 session 1 的 claim UPDATE 先跑完並鎖住它那 5 筆（不需要等 session 1
-- commit，只要它的 UPDATE 已經鎖住列）——這段期間 session 1 仍在 pg_sleep(2) 內，
-- 交易尚未結束，鎖仍然持有。

\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_n int;
begin
  perform pg_sleep(0.5);
  insert into public.ls172_claim_race_capture (session, event_id)
  select 's2', id from public.claim_notification_events(5);
  get diagnostics v_n = row_count;
  if v_n <> 5 then
    raise exception 'S2 FAIL：應該剛好 claim 到剩下的 5 筆，實際 %（若是 0 筆，可能是 SKIP LOCKED 沒有正確跳過 S1 鎖住的列，反而被卡住等待）', v_n;
  end if;
  raise notice 'S2：已 claim 5 筆（S1 鎖住的另外 5 筆之外的部分）';
end;
$$;

commit;

\echo 'S2 done'
