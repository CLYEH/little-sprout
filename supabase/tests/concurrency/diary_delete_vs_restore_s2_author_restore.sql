-- 併發場景（LS-57：owner 軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的
-- 時候呼叫還原。
--
-- 這是 `set_diary_deleted` 開頭那句 `select ... for update` 對 LS-57 還原鎖真正
-- 必要的地方：這支 RPC 的還原鎖（private.enforce_deletion_attribution() trigger）
-- 判斷「這篇是不是別人刪的」靠的是 `old.deleted_by`——若 S2 的初始 SELECT 沒有鎖住
-- 這一列，READ COMMITTED 下它會在 S1 commit 之前就讀到舊快照：`deleted_at`／
-- `deleted_by` 都還是 NULL（S1 的軟刪對 S2 而言不可見，因為還沒 commit）。S2 接著
-- 執行的 UPDATE 會把 `deleted_at` 設回 NULL——這件事本身是 no-op（改之前就是
-- NULL），但問題是 S2 的整個授權路徑（RPC 的成員檢查＋trigger 的還原鎖）全部是用
-- 這份過期快照做判斷，不是「先等 S1 講清楚這篇現在被誰刪除、再決定能不能還原」。
-- 有 `for update`：S2 的 SELECT 會等 S1 commit 之後才讀到列，讀到的 `deleted_by`
-- 已經是 owner，`set_diary_deleted` 的還原鎖（見 migration）正確地噴出 `LS027`，
-- `deleted_at` 完全沒被 S2 的 UPDATE 動過（見 verify 檔）。
--
-- Mutation 證據（本機用 Supabase CLI 映像實測）：把 `set_diary_deleted` 開頭
-- `select d.* into v_diary from public.diaries d where d.id = p_diary_id for
-- update;` 的 `for update` 拿掉，重跑這個場景：S2 不再被阻塞（等待時間遠低於
-- 0.5 秒）、也沒有拿到 `LS027`——這個檔案的兩條斷言與 verify 檔的斷言都會變紅，
-- 證實這把鎖對 LS-57 的還原鎖同樣是行為必要的，不是防禦性寫法。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls027 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a3000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 set_diary_deleted（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.set_diary_deleted('57000000-0000-4000-8000-000000000001', false);
  exception
    when sqlstate 'LS027' then v_ls027 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：沒被擋下的還原要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，LS027=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls027, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：作者的還原沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— set_diary_deleted 沒有對日記列取鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls027 then
    raise exception
      'FAIL 併發：owner 剛軟刪的日記，作者竟然能還原成功（錯誤碼 %）—— LS-57 的還原鎖用了過期資料做判斷',
      coalesce(v_other, '沒有任何錯誤');
  end if;

  raise notice 'ok 併發：作者的還原被阻塞後拿到 LS027';
end;
$$;
