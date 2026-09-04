-- LS-172 R2 i5 情境二，session 1：claim 走事件 X，故意壓住 2 秒不 commit——這 2 秒
-- 是 session 2（新留言→record_notification_event）的併發窗口。

\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_claimed_id uuid;
  v_expected uuid := 'c5000000-0000-4000-8000-000000000001';
  v_n int;
begin
  select id into v_claimed_id from public.claim_notification_events(50);
  get diagnostics v_n = row_count;
  if v_n <> 1 or v_claimed_id is distinct from v_expected then
    raise exception 'S1 FAIL：預期剛好 claim 到事件 X（%），實際 % 筆，id=%', v_expected, v_n, v_claimed_id;
  end if;
  insert into public.ls172_claim_vs_record_capture (session, claimed_id) values ('s1', v_claimed_id);
  raise notice 'S1：已 claim 事件 X（%），held 住交易 2 秒', v_claimed_id;
end;
$$;

select pg_sleep(2);
commit;

\echo 'S1 done'
