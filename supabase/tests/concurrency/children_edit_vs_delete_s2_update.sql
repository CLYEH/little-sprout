-- 併發場景（方向 B：軟刪先動）的 session 2：member 在 owner 還沒 commit 軟刪的時候編輯。
--
-- R1（merge-reviewer PR #95 review M1）訂正：第 1 條斷言（阻塞）的來源是 owner 那筆
-- set_child_deleted 交易自己的 UPDATE 語句尚未 commit（任何 UPDATE 都會對命中的列
-- 取得排他列鎖直到交易結束，這是 Postgres 通用行為，不是「set_child_deleted 有沒有
-- 寫 for update」這句特定語法的功勞——四種 mutation 實測過，拿掉 set_child_deleted
-- 的 for update，這個方向仍然維持阻塞）。真正驗到的是第 2 條斷言：**update_child
-- 開頭那句 for update 是必要的**——這是本組併發測試唯一真的會紅的 mutation（見
-- `children_edit_vs_delete_s1_delete.sql` 檔頭），拿掉它會讓下面的第 2 步驟不再讀到
-- owner 剛 commit 的最新 `deleted_at`，改用 READ COMMITTED 下一句不上鎖的 SELECT
-- 會拿到的舊快照（`deleted_at` 仍是 NULL），授權與狀態檢查就會誤判成「還沒被移除」
-- 而放行，等到函式尾端真正的 UPDATE 才會因為列鎖阻塞、解除後把新內容寫回一個已經
-- 被 owner 判定該移除的孩子檔案——「軟刪之後內容不會再被改動」這條保證就破了。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——阻塞來自 owner 那筆 set_child_deleted 交易尚未 commit（見上）。
--   2. 解除阻塞後必須噴 **LS041**：READ COMMITTED 下 `for update` 取得列鎖之後會
--      重讀最新列版本，讀到 deleted_at 已經被 owner 設成非 NULL，被 update_child 裡
--      「授權通過之後才檢查的軟刪狀態」擋下——member 身分與 contributor 資格都還
--      成立，卡在的是「已被移除」這個狀態（見 migration 對 update_child 授權排在
--      狀態檢查之前的說明）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls041 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 set_child_deleted（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.update_child(
      '29000000-0000-4000-8000-000000000001', '軟刪之後還想改', date '2025-01-01', null);
  exception
    when sqlstate 'LS041' then v_ls041 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：沒被擋下的編輯要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，LS041=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls041, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：member 的編輯沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— owner 那筆 set_child_deleted 交易應該還沒 commit、仍持有列鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls041 then
    raise exception
      'FAIL 併發：已被軟刪的孩子檔案竟然還能被編輯成功（錯誤碼 %）—— 軟刪之後內容不該再被改動',
      coalesce(v_other, '沒有任何錯誤');
  end if;

  raise notice 'ok 併發：member 的編輯被阻塞後拿到 LS041';
end;
$$;
