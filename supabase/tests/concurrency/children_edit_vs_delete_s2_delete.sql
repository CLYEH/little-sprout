-- 併發場景（方向 A：編輯先動）的 session 2：owner 在 member 還沒 commit 編輯的時候軟刪。
--
-- R1（merge-reviewer PR #95 review M1）訂正：阻塞的來源是 member 那筆
-- update_child 交易**自己的 UPDATE 語句**尚未 commit——任何一句 UPDATE 都會對命中
-- 的列取得排他列鎖直到交易結束，這是 Postgres 通用的列鎖行為，跟 set_child_deleted
-- 有沒有在自己開頭多寫一句 `for update` 無關。四種 mutation 實測過（拿掉
-- update_child 的 `for update`／拿掉 set_child_deleted 的 `for update`，各自在方向
-- A／方向B 各跑一次）：本檔（方向A 的 session 2）在兩種 mutation 下都維持綠燈，
-- 對兩支 RPC 的鎖都是不可證偽的——本檔驗的是「阻塞確實發生、且 owner 的軟刪解除
-- 阻塞後正常成功」這個時序保證本身，不是任何一支 RPC 特定那句 `for update` 的
-- 回歸覆蓋（那句覆蓋由方向B、`children_edit_vs_delete_s2_update.sql` 提供——拿掉
-- update_child 的 `for update` 會讓那個方向真的變紅，見該檔案說明）。
--
-- set_child_deleted 開頭那句 `select ... for update` 仍然刻意保留：它是讀
-- `family_id`（授權判斷用）當下上鎖的 TOCTOU 防線（LS-52 定下的規則——任何 RPC
-- 授權判斷讀到的列都要先鎖住，避免讀完到真正 UPDATE 之間那個資料被搬家），是純防禦
-- 性的正確作法，只是本檔的計時斷言證明不了它——`family_id` 有 immutable trigger
-- 擋著搬家，這裡也沒有建構出讓它單獨扮演關鍵角色的情境。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——阻塞來自 member 那筆 update_child 交易尚未 commit（見上）。
--   2. 解除阻塞後必須**成功**（不是錯誤）：set_child_deleted 完全不檢查內容或
--      「這個孩子檔案是否正在被編輯」，它只在乎能不能拿到列鎖。拿到鎖之後，軟刪本來
--      就該直接成功——這裡驗的是「編輯的內容先落地，軟刪才動作」這個順序，不是驗
--      軟刪會被擋下（最終狀態的斷言見 children_edit_vs_delete_verify_update_won.sql）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 update_child（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_child_deleted('29000000-0000-4000-8000-000000000001', true);
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
      'FAIL 併發：owner 的軟刪沒有被 member 的編輯阻塞（僅等待 % 秒）—— member 那筆 update_child 交易應該還沒 commit、仍持有列鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：owner 軟刪這個孩子檔案竟然出錯（%）—— set_child_deleted 不該因為內容正在被編輯而失敗',
      v_error;
  end if;

  raise notice 'ok 併發：owner 的軟刪被 member 的編輯阻塞，解除阻塞後正常成功';
end;
$$;
