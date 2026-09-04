-- LS-172 R2 i5 情境一，session 1：claim 5 筆、故意壓住 2 秒不 commit。
--
-- 這 2 秒是 session 2 的窗口：claim_notification_events() 內部的
-- `FOR UPDATE SKIP LOCKED` 若正確運作，session 2 在這段期間呼叫同一支函式應該
-- 跳過這裡鎖住的 5 筆，只拿到剩下未鎖的那 5 筆——不會兩邊都拿到同一批。

\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_n int;
begin
  insert into public.ls172_claim_race_capture (session, event_id)
  select 's1', id from public.claim_notification_events(5);
  get diagnostics v_n = row_count;
  if v_n <> 5 then
    raise exception 'S1 FAIL：應該剛好 claim 到 5 筆，實際 %', v_n;
  end if;
  raise notice 'S1：已 claim 5 筆，held 住交易 2 秒後才會 commit';
end;
$$;

select pg_sleep(2);
commit;

\echo 'S1 done'
