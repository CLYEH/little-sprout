-- 併發場景（LS-57：owner 軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的
-- 時候呼叫還原。
--
-- R1（merge-reviewer PR #98 review B4）指出：這裡原本宣稱「set_diary_deleted 開頭
-- 那句 `for update` 是這個場景被正確擋下的必要條件」——實測（拿掉 `for update`、
-- 重跑這個場景）證實這個宣稱不成立，改記錄事實：
--
-- 這個場景真正被擋下（S2 被阻塞、解除阻塞後拿到 LS027）靠的是 diaries 表本身
-- 掛的 `enforce_deletion_attribution()` BEFORE UPDATE trigger——Postgres 對「目標列
-- 有 BEFORE ROW UPDATE trigger」的 UPDATE 語句，執行期的 `GetTupleForTrigger()` 本來
-- 就會在觸發 trigger 之前對那一列取 `LockTupleExclusive`；若鎖不到（另一個交易的
-- UPDATE 正持有鎖），會等待、解鎖後用 EvalPlanQual 重取最新版本當 trigger 的
-- `OLD`。這件事**不需要**呼叫端的 SELECT 帶 `FOR UPDATE`——S1 自己那句
-- `update ... set deleted_at = ...`（不論它前面的診斷用 SELECT 有沒有鎖）本身就會
-- 持有列鎖直到 commit；S2 的 `set_diary_deleted` 最終那句 UPDATE 撞上這把鎖時，
-- 一樣會被阻塞，解除阻塞後 trigger 讀到的 `OLD.deleted_by` 已經是 owner，正確噴出
-- `LS027`。`for update` 拿掉之後重跑本檔：兩條斷言（`v_elapsed`／`v_ls027`）與
-- verify 檔的斷言全部維持通過，不會變紅。
--
-- `set_diary_deleted` 的 `for update` 因此對**這個場景**是多餘的、不是必要條件——
-- 但這不代表它是可以刪掉的死碼：LS-48 既有的 `diary_edit_vs_delete` 併發場景
-- （`update_diary_entry` vs `set_diary_deleted`）仍然是這把鎖曾經被 mutation
-- 證實過必要的地方，只是必要性來自**另一支函式**（`update_diary_entry` 自己那句
-- `for update`，保護它自己「是否已軟刪除」的檢查不用到過期快照），不是
-- `set_diary_deleted` 這一支——本檔重新用同一個 mutation（拿掉 `set_diary_deleted`
-- 的 `for update`）對 `diary_edit_vs_delete` 方向 B 重跑過，兩條斷言與 verify 一樣
-- 全綠，代表 `set_diary_deleted` 自己那句 `for update` 在目前全部已知場景下都是
-- 冗餘的。R2（merge-reviewer PR #98 review N1/N2）之後：`albums`／`diaries`／
-- `comments` 三表的 `deleted_at`／`deleted_by`／`family_id` 三欄已對 authenticated
-- 收回 UPDATE 欄位級 grant（見 `20260825040000_deletion_attribution.sql`），
-- `family_id` 無法再由任何呼叫端（不論單句或多句）直接改動，`set_album_deleted`
-- 那組 race 原本擔心的「授權讀取當下 family_id 是過期值」的 TOCTOU 前提已經不存在
-- ——`for update` 仍然保留，作為授權讀取（`select ... for update` 讀 `family_id`／
-- `author_id` 做授權判斷）的 TOCTOU 防線：這是防禦性寫法，不是回應一個目前測得到
-- 的具體場景（家族三支 RPC 內部邏輯若未來變動、或有繞過欄位級 grant 的路徑
-- 出現，這把鎖能繼續擋住同一類「讀的時候還沒變、寫的時候已經變了」的問題），
-- 移除它需要先確認所有相依場景都真的用不到，不在本票範圍內處理。
--
-- 本檔仍然是有意義的回歸測試：它驗證的是「owner 軟刪 vs 作者還原」這個 race 的
-- **最終行為**（作者必須被正確擋下、拿到 LS027，不能用過期資料矇混過關）——只是
-- 承擔這件事的機制是 trigger 的列鎖，不是這支 RPC 自己的 `for update`。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls027 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"d2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
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
