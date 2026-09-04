-- Session 2：owner 在 purge 還沒 commit 的時候嘗試還原同一個孩子。
--
-- set_child_deleted(false) 開頭就是 `select … for update`（見
-- 20260825030000_children_write_path_and_soft_delete.sql）——這句話會被 S1 那筆
-- DELETE 尚未 commit 持有的排他列鎖擋住，解除阻塞後重讀到的是「這一列已經不存在」
-- （S1 已經把它刪掉並 commit），`select … into … for update` 找不到列，
-- `if not found` 分支直接給 LS041（「孩子檔案不存在」），不是 LS043（「超過 30 天
-- 無法還原」——那個碼假設列還在、只是還原窗口過期；這裡列已經物理消失，語意上是
-- 更準確的 LS041，兩者都代表「還原這個動作不會成功」，但只有 LS041 精確描述了
-- 「purge 已經跑贏」這個結果，測試斷言要對到這個碼，不能只籠統驗『有錯誤就好』）。
--
-- 兩條斷言（比照 children_edit_vs_delete_s2_update.sql 的既有慣例）：
--   1. 必須「被阻塞」——阻塞來自 S1 那筆 purge_expired() 交易尚未 commit。
--   2. 解除阻塞後必須噴 LS041（不是 LS043，也不是靜默成功）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls041 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"b9000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 S1 的 purge_expired()（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_child_deleted('2f000000-0000-4000-8000-000000000001', false);
  exception
    when sqlstate 'LS041' then v_ls041 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，LS041=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls041, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：owner 的還原沒有被 purge_expired() 阻塞（僅等待 % 秒）—— S1 那筆 DELETE 交易應該還沒 commit、仍持有列鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls041 then
    raise exception
      'FAIL 併發：已被 purge 硬刪的孩子檔案，還原竟然沒有拿到 LS041（實際：%）',
      coalesce(v_other, '沒有任何錯誤——竟然還原成功了');
  end if;

  raise notice 'ok 併發：owner 的還原被 purge_expired() 阻塞後，正確拿到 LS041（孩子檔案已不存在）';
end;
$$;
