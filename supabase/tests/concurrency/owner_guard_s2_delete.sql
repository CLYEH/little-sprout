-- 併發場景「兩個 owner 同時被移除」的 session 2（DELETE 路徑）。斷言與降級版本相同。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_raised boolean := false;
begin
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    delete from public.family_members
     where family_id = 'fd000000-0000-4000-8000-000000000001'
       and user_id = 'd0000000-0000-4000-8000-000000000002';
  exception when sqlstate 'LS001' then
    v_raised := true;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 同 owner_guard_s2_demote.sql：先定案再斷言，讓磚化後果對 verify 可見
  commit;

  raise notice 'S2 移除：等待 % 秒後結束，LS001=%', round(v_elapsed::numeric, 2), v_raised;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的移除沒有被同家庭的 S1 阻塞（僅等待 % 秒）',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_raised then
    raise exception
      'FAIL 併發：S2 的移除沒有噴 LS001 —— 兩位 owner 被同時移除，家庭將剩 0 位 owner（永久磚化）';
  end if;

  raise notice 'ok 併發：S2 的移除被阻塞後噴 LS001';
end;
$$;
