-- LS-172 R2 i5 情境一：最終狀態斷言——S1／S2 claim 到的事件集合完全不重疊，
-- 合計剛好等於全部 10 筆。

\set ON_ERROR_STOP on

do $$
declare
  v_s1 int;
  v_s2 int;
  v_overlap int;
  v_total_marked int;
begin
  select count(*) into v_s1 from public.ls172_claim_race_capture where session = 's1';
  select count(*) into v_s2 from public.ls172_claim_race_capture where session = 's2';

  select count(*) into v_overlap from (
    select event_id from public.ls172_claim_race_capture
     group by event_id having count(distinct session) > 1
  ) dup;

  select count(*) into v_total_marked from public.notification_events
   where family_id = 'c2000000-0000-4000-8000-000000000001' and sent_at is not null;

  if v_s1 <> 5 then
    raise exception 'FAIL 併發：S1 應該剛好 claim 到 5 筆，實際 %', v_s1;
  end if;
  if v_s2 <> 5 then
    raise exception 'FAIL 併發：S2 應該剛好 claim 到 5 筆，實際 %', v_s2;
  end if;
  if v_overlap <> 0 then
    raise exception 'FAIL 併發：S1／S2 claim 到重疊的事件（% 筆重複）——FOR UPDATE SKIP LOCKED 沒有正確防止併發 claim 重疊', v_overlap;
  end if;
  if v_total_marked <> 10 then
    raise exception 'FAIL 併發：全部 10 筆事件應該都已標記 sent_at，實際 %', v_total_marked;
  end if;

  raise notice 'ok 併發：兩個並行 claim_notification_events() 呼叫，claim 到的集合完全不重疊（各 5 筆，合計剛好 10 筆，10 筆皆已標記 sent_at）';
end;
$$;
