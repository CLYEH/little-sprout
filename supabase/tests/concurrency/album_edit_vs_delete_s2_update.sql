-- 併發場景（方向 B：軟刪先動）的 session 2：作者在 owner 還沒 commit 軟刪的時候
-- 直接 UPDATE 標題。
--
-- 與 diaries 的 diary_edit_vs_delete_s2_update.sql 不同（重要，別套用那邊的心智
-- 模型）：`update_diary_entry` 明確檢查 `deleted_at is not null` 並回報 LS020，
-- 拒絕編輯已被移除的日記；`albums_update` policy **沒有**這個檢查（本票 LS-52
-- 的 scope 只收斂 owner 分支不限欄位這件事，沒有新增「已軟刪除不能編輯」這個
-- 業務規則——這是另一個系統性議題，merge-reviewer PR #70 review F4「owner 移除
-- 可被作者還原」點名的同一類缺口，orchestrator 已表示另開票處理，不在本票夾帶）。
-- 所以這裡解除阻塞後**應該成功**，不是拿到錯誤碼——這個檔案驗的是「序列化正確
-- 發生、沒有互相覆蓋掉對方寫的欄位」，不是「編輯會被軟刪擋下」。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 set_album_deleted（含尾端 UPDATE 取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  update public.albums set title = '軟刪之後還想改'
   where id = '49000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後結束，影響 % 列', round(v_elapsed::numeric, 2), v_n;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：作者的直接 UPDATE 沒有被 owner 的軟刪阻塞（僅等待 % 秒）—— set_album_deleted 尾端的 UPDATE 沒有真的鎖住這一列',
      round(v_elapsed::numeric, 2);
  end if;

  if v_n <> 1 then
    raise exception
      'FAIL 併發：作者編輯自己的相簿（仍是該家庭 contributor）解除阻塞後應該成功，實際影響 % 列——albums_update policy 的作者分支被本次併發意外擋下了',
      v_n;
  end if;

  raise notice 'ok 併發：作者的直接 UPDATE 被 owner 的軟刪阻塞，解除阻塞後正常成功（albums 沒有「已軟刪除不能編輯」的規則，見檔頭說明）';
end;
$$;
