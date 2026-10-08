-- 併發場景（軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的時候編輯同一筆紀錄。
--
-- 兩條斷言：
--   1. 必須「被阻塞」（v_elapsed ≥ 0.5 秒）——owner 的軟刪交易持有這筆紀錄的列鎖，
--      upsert_growth_record 的 UPDATE 必須在同一列上排隊。
--   2. 解除阻塞後必須噴 **42501**（「成長紀錄不存在，或您不是這筆紀錄的作者」）：READ
--      COMMITTED 下等到列鎖之後會在最新列版本上重新檢查條件（含 growth_records_select 的
--      `deleted_at is null`），軟刪已落地 → 命中 0 列 → upsert_growth_record 自己 raise
--      42501。growth_records 不開自訂碼（見 migration 20260913065021 upsert_growth_record 上方說明）。
--
-- 沒有阻塞的話，作者的 UPDATE 會在軟刪 commit 前就改掉內容，「軟刪之後內容不會再被改動」
-- 這條保證就破了（最終狀態斷言見 growth_record_delete_vs_edit_verify.sql）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_42501 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"75000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 delete_growth_record（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.upsert_growth_record(
      '77000000-0000-4000-8000-000000000001', '76000000-0000-4000-8000-000000000001',
      current_date, 99.0, null, null, '軟刪之後還想改');
  exception
    when sqlstate '42501' then v_42501 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：沒被擋下的編輯要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，42501=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_42501, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：作者的編輯沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— delete_growth_record 沒有對紀錄列取鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_42501 then
    raise exception
      'FAIL 併發：已被軟刪的成長紀錄竟然還能被編輯成功（錯誤碼 %）—— 軟刪之後內容不該再被改動',
      coalesce(v_other, '沒有任何錯誤');
  end if;

  raise notice 'ok 併發：作者的編輯被阻塞後拿到 42501';
end;
$$;
