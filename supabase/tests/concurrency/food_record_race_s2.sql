-- LS-325 併發場景 session 2：等 S1 先取到（隱含於 INSERT ... ON CONFLICT 衝突偵測
-- 的）鎖之後，才對同一寶貝同一食物再次呼叫 upsert_child_food_record——必須被 S1
-- 阻塞，解除阻塞後才真正執行，讀到的是 S1 已經 commit 之後的既存列，轉為更新，
-- 寫出的是自己的值。
--
-- 這是同一位作者（S1／S2 都是同一個 profiles.id）重疊呼叫的情境（例如使用者不小心
-- 連點兩次「記一筆」）——票面「並發：...第二筆得到明確錯誤或轉為更新」的「轉為
-- 更新」那一支；「明確錯誤」那一支（不同作者互相踩線）不需要真正的時序交錯就能
-- 決定性重現，已用一般（非併發）SQL 斷言覆蓋，見
-- supabase/tests/117_food_encyclopedia.sql §6 (c)。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"72000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 upsert_child_food_record（含 INSERT）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.upsert_child_food_record(
    '73000000-0000-4000-8000-000000000001', 'banana', date '2026-01-02', null, 'S2 記錄', 'disliked');
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後完成，banana 已轉為更新', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 upsert_child_food_record 沒有被 S1 阻塞（僅等待 % 秒）——ON CONFLICT 對同一寶貝同一食物的兩次重疊呼叫沒有序列化',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
