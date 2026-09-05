-- LS-172 R2 i5 情境二：最終狀態斷言——claim 標記 sent_at 之後，同一目標的新事件
-- 不會混進已 claim 的列，而是正確開新列。

\set ON_ERROR_STOP on

do $$
declare
  v_x_sent_at timestamptz;
  v_x_event_count int;
  v_total int;
  v_new_id uuid;
  v_new_sent_at timestamptz;
  v_new_event_count int;
begin
  select sent_at, event_count into v_x_sent_at, v_x_event_count
    from public.notification_events where id = 'c5000000-0000-4000-8000-000000000001';

  if v_x_sent_at is null then
    raise exception 'FAIL 併發：事件 X 應該已經被 S1 claim（sent_at 非 NULL），實際是 NULL';
  end if;
  if v_x_event_count <> 1 then
    raise exception 'FAIL 併發：事件 X 的 event_count 應該維持原本的 1（沒有被 S2 的新留言誤合併進去），實際 %', v_x_event_count;
  end if;

  select count(*) into v_total from public.notification_events
   where family_id = 'c2000000-0000-4000-8000-000000000002'
     and kind = 'comment' and target_type = 'diary'
     and target_id = 'c4000000-0000-4000-8000-000000000001';
  if v_total <> 2 then
    raise exception 'FAIL 併發：應該恰好有 2 筆事件（已 claim 的事件 X ＋ 因為 X 已 claim 而新開的一筆），實際 %', v_total;
  end if;

  select id, sent_at, event_count into v_new_id, v_new_sent_at, v_new_event_count
    from public.notification_events
   where family_id = 'c2000000-0000-4000-8000-000000000002'
     and kind = 'comment' and target_type = 'diary'
     and target_id = 'c4000000-0000-4000-8000-000000000001'
     and id <> 'c5000000-0000-4000-8000-000000000001';

  if v_new_sent_at is not null then
    raise exception 'FAIL 併發：新開的事件應該還沒送出（sent_at 是 NULL），實際 %', v_new_sent_at;
  end if;
  if v_new_event_count <> 1 then
    raise exception 'FAIL 併發：新開的事件 event_count 應該是 1（單一則新留言，沒有誤合併進舊的已 claim 事件），實際 %', v_new_event_count;
  end if;

  raise notice 'ok 併發：claim_notification_events 標記 sent_at 之後，同一目標的新事件不會混進已 claim 的列，而是正確開新列（事件 X event_count 仍是 1、sent_at 已標記；新列 % event_count=1、sent_at 仍 NULL）', v_new_id;
end;
$$;
