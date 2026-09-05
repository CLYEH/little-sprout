-- LS-206 merge-review R1 m1 併發場景「owner 幾乎同時對兩個不同對象各發一次
-- transfer_ownership」的 session 2。
--
-- O 在 S1 已經 commit（S1 的 3 秒 pg_sleep 之後）才真正解除阻塞。此時 O 已經
-- 被 S1 降為 member——O 呼叫 transfer_ownership(family, B) 時，兩句 FOR UPDATE
-- 先被 S1 持有的鎖擋住（O 這一列），解鎖後用全新查詢重新讀到 O 的角色已經是
-- member，正確拿到 LS058（不是 TOCTOU 造成的悄悄成功）。若 migration 拿掉這兩句
-- FOR UPDATE（reviewer 實測的 mutant），S2 會在鎖之前的 SELECT 就讀到 O 仍是
-- owner 的過期值，通過檢查後才在自己的 UPDATE 上被 S1 的鎖擋住，解鎖後 UPDATE
-- 對 O 這一列的 WHERE 子句與角色無關、仍會成功執行——最終 A、B 都被扶正成
-- owner（見 transfer_race_verify.sql 的斷言）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_raised boolean := false;
begin
  perform pg_sleep(1.2);

  perform set_config('request.jwt.claims',
    '{"sub":"de100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  v_t0 := clock_timestamp();
  begin
    perform public.transfer_ownership(
      'de000000-0000-4000-8000-000000000001', 'de100000-0000-4000-8000-000000000003');
  exception when sqlstate 'LS058' then
    v_raised := true;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);
  reset role;

  -- 先定案再斷言：無論成功與否都要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，LS058=%', round(v_elapsed::numeric, 2), v_raised;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 transfer_ownership() 沒有被 S1 阻塞（僅等待 % 秒）——兩句 FOR UPDATE 沒有排到 S1 持有的 O 這一列鎖後面',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_raised then
    raise exception
      'FAIL 併發：S2 的 transfer_ownership() 沒有噴 LS058——O 已經被 S1 降為 member，S2 仍用過期的 role 判斷讓 B 也被扶正成 owner（TOCTOU 沒有被鎖住）';
  end if;

  raise notice 'ok 併發：S2 的 transfer_ownership() 被阻塞後正確拿到 LS058（O 已非 owner，不會讓 B 也被錯誤扶正）';
end;
$$;
