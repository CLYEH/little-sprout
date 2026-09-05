-- LS-172 R2 i5 情境一：最終狀態斷言——S1／S2 claim 到的事件集合完全不重疊，
-- 合計剛好等於全部 10 筆。

\set ON_ERROR_STOP on

-- LS-96 池項 8519d8a4 第 2 條（merge-review R2-i2）：耗時閾值——S1 於 claim 完
-- 成後 pg_sleep(2) 才 commit，S2 於 t=0.5s 開始呼叫 claim_notification_events()。
-- SKIP LOCKED 正確運作時，S2 只是跳過已鎖的列去掃描剩下的，耗時應該是毫秒等級
-- （遠低於 1 秒）；若 SKIP LOCKED 被拿掉（改成單純 FOR UPDATE），S2 會被 S1
-- 鎖住的列卡住，直到 S1 於 t≈2.0s commit 才能繼續（等待窗口 ≈1.5 秒），耗時
-- 會遠超過 1 秒。閾值定在 1000ms：對「正確運作」留了充足餘裕（本機實測通常
-- 個位數毫秒），對「SKIP LOCKED 被拿掉」也留了充足餘裕（預期阻塞 ≈1.5 秒）。
do $$
declare
  v_s1 int;
  v_s2 int;
  v_overlap int;
  v_total_marked int;
  v_s2_duration_ms numeric;
begin
  select count(*) into v_s1 from public.ls172_claim_race_capture where session = 's1';
  select count(*) into v_s2 from public.ls172_claim_race_capture where session = 's2';
  select claim_duration_ms into v_s2_duration_ms
    from public.ls172_claim_race_capture where session = 's2' limit 1;

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
  if v_s2_duration_ms is null then
    raise exception 'FAIL 併發：S2 沒有記到 claim_duration_ms（測試本身的埋樁壞了）';
  end if;
  if v_s2_duration_ms > 1000 then
    raise exception 'FAIL 併發：S2 呼叫 claim_notification_events() 耗時 % ms，超過 1000ms 閾值——SKIP LOCKED 疑似沒有正確跳過 S1 鎖住的列，反而被卡住等待 S1 commit（merge-review R2-i2）', round(v_s2_duration_ms, 1);
  end if;

  raise notice 'ok 併發：兩個並行 claim_notification_events() 呼叫，claim 到的集合完全不重疊（各 5 筆，合計剛好 10 筆，10 筆皆已標記 sent_at），S2 耗時 % ms（遠低於 S1 持有的 2 秒，證明沒有被卡住等待，真正釘住 SKIP LOCKED 的「不阻塞」性質）', round(v_s2_duration_ms, 1);
end;
$$;
