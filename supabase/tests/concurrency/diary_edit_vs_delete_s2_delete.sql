-- 併發場景（方向 A：編輯先動）的 session 2：owner 在作者還沒 commit 編輯的時候軟刪。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——update_diary_entry 用 `for update` 鎖住日記列，
--      set_diary_deleted 的 `for update` 才會在同一列上排隊等待。
--   2. 解除阻塞後必須**成功**（不是錯誤）：set_diary_deleted 完全不檢查內容或
--      「這篇日記是否正在被編輯」，它只在乎能不能拿到列鎖。拿到鎖之後，軟刪本來就
--      該直接成功——這裡驗的是「編輯的內容先落地，軟刪才動作」這個順序，不是驗
--      軟刪會被擋下（最終狀態的斷言見 diary_edit_vs_delete_verify_update_won.sql）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"g0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 update_diary_entry（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_diary_deleted('5g000000-0000-4000-8000-000000000001', true);
  exception
    when others then v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：無論成功與否都要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%',
    round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：owner 的軟刪沒有被作者的編輯阻塞（僅等待 % 秒）—— update_diary_entry 沒有對日記列取鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這篇日記竟然出錯（%）—— set_diary_deleted 不該因為內容正在被編輯而失敗',
      v_error;
  end if;

  raise notice 'ok 併發：owner 的軟刪被作者的編輯阻塞，解除阻塞後正常成功';
end;
$$;
