-- 鎖強度探針（LS-419）的 session 2：owner 在 session 1 還持有 FOR KEY SHARE 時呼叫
-- delete_growth_record。為什麼要這組，見 growth_record_delete_vs_edit_s1_keyshare.sql 檔頭。
--
-- 兩條斷言：
--   1. 必須「被阻塞」（v_elapsed ≥ 0.5 秒）——delete_growth_record 讀 family_id／author_id
--      做授權判斷之前先 `select … for update`，FOR UPDATE 與 FOR KEY SHARE 衝突而排隊。
--      拿掉 for update 的話，函式只剩一般 UPDATE（FOR NO KEY UPDATE），不和 FOR KEY SHARE
--      衝突，不會等待 → 這條紅。
--   2. 解除阻塞後必須成功：探針只佔鎖、不改資料，軟刪照常落地（終態斷言沿用
--      growth_record_delete_vs_edit_verify.sql：deleted_at 已設、deleted_by＝owner、內容不變）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"75000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 FOR KEY SHARE 先拿到
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.delete_growth_record('77000000-0000-4000-8000-000000000001');
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：delete_growth_record 沒有被 FOR KEY SHARE 阻塞（僅等待 % 秒）—— 授權判斷前的 `select … for update` 不見了',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這筆成長紀錄竟然出錯（%）—— 探針只佔鎖、不改資料，軟刪應正常成功',
      v_error;
  end if;

  raise notice 'ok 併發：delete_growth_record 先以 FOR UPDATE 鎖列（被 FOR KEY SHARE 阻塞），解除後正常成功';
end;
$$;
