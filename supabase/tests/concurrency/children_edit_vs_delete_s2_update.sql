-- 併發場景（方向 B：軟刪先動）的 session 2：member 在 owner 還沒 commit 軟刪的時候編輯。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——set_child_deleted 用 `for update` 鎖住孩子檔案列，
--      update_child 的 `for update` 才會在同一列上排隊等待。
--   2. 解除阻塞後必須噴 **LS041**：READ COMMITTED 下取得列鎖之後會重讀最新列版本，
--      讀到 deleted_at 已經被 owner 設成非 NULL，被 update_child 裡「授權通過之後
--      才檢查的軟刪狀態」擋下——member 身分與 contributor 資格都還成立，卡在的是
--      「已被移除」這個狀態（見 migration 對 update_child 授權排在狀態檢查之前的說明）。
--
-- 沒有那把鎖的話，member 會讀到 deleted_at 還是 NULL 而往下走，把新內容寫回一個已經
-- 被 owner 判定該移除的孩子檔案——「軟刪之後內容不會再被改動」這條保證就破了。

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
      'FAIL 併發：member 的編輯沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— set_child_deleted 沒有對孩子檔案列取鎖',
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
