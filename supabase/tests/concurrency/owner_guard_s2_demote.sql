-- 併發場景「兩個 owner 同時被降級」的 session 2。
--
-- 兩條斷言，缺一不可：
--   1. 必須「被阻塞」——不變量檢查前要先鎖住 families 列，同一家庭的降級才會排隊。
--      沒有鎖的話 session 2 會立刻返回（等待 ≈ 0 秒）。
--   2. 排到之後必須噴 LS001——重新讀到的狀態是「owner 1 已降級」，此時再降 owner 2 就是 0 owner。
--
-- 只驗第 2 條不夠：如果 session 2 是因為別的原因失敗（例如 owner 1 的降級也被誤擋），
-- 等待時間會接近 0，那不是我們要的序列化行為。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_raised boolean := false;
begin
  -- 讓 session 1 的 UPDATE（含 statement trigger 取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    update public.family_members set role = 'member'
     where family_id = 'fd000000-0000-4000-8000-000000000001'
       and user_id = 'd0000000-0000-4000-8000-000000000002';
  exception when sqlstate 'LS001' then
    v_raised := true;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先把 S2 的結果定案再斷言：沒被擋下的降級要真的留在資料庫裡，
  -- owner_guard_verify.sql 才看得到「0 位 owner」這個實際後果，
  -- 而不是被本測試自己的 rollback 掩蓋掉。
  commit;

  raise notice 'S2 降級：等待 % 秒後結束，LS001=%', round(v_elapsed::numeric, 2), v_raised;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的降級沒有被同家庭的 S1 阻塞（僅等待 % 秒）—— 不變量檢查沒有序列化，兩個降級會各自看到對方還是 owner',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_raised then
    raise exception
      'FAIL 併發：S2 的降級沒有噴 LS001 —— 兩個併發降級同時放行，家庭將剩 0 位 owner（永久磚化，無自救路徑）';
  end if;

  raise notice 'ok 併發：S2 的降級被阻塞後噴 LS001';
end;
$$;
