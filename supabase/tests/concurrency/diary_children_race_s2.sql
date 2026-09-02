-- LS-121 併發場景 session 2：等 S1 的 `for update` 先取到鎖之後，才把孩子標記整組
-- 換成 {D}——必須被 S1 阻塞，解除阻塞後才真正執行，讀到的是 S1 已經 commit 之後的
-- 狀態，寫出的是自己完整、覆蓋後的集合。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 update_diary_entry（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.update_diary_entry(
    '58000000-0000-4000-8000-000000000001', 'S2 改的內容', current_date,
    array['28000000-0000-4000-8000-000000000004']::uuid[]);
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後完成，孩子標記整組換成 {D}', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 update_diary_entry 沒有被 S1 阻塞（僅等待 % 秒）—— update_diary_entry 開頭的 `for update` 沒有真的鎖住日記列',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
