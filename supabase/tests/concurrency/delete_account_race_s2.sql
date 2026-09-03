-- LS-143 併發場景「兩位共同 owner 同時刪除帳號」的 session 2。
--
-- owner 2 在 owner 1 已經 commit（S1 的 3 秒 pg_sleep 之後）才真正解除阻塞。此時
-- owner 1 已經離開家庭，owner 2 是家庭僅剩的成員——owner 2 自己的
-- delete_my_account() 這次執行時，一開始的守門查詢（在它自己的交易快照下）看到
-- 的仍是「owner 1 還在、我不是唯一 owner」（READ COMMITTED 下看不到 S1 尚未
-- commit 前、也就是自己開始執行當下的未提交變更），於是照樣走「正常離開家庭」
-- 這條路——但它自己的 DELETE FROM family_members 這句話一執行完，family
-- d3000000-...001 就會變成 0 位成員，既有的 private.enforce_family_has_owner()
-- trigger（此時才真正取得鎖、看到 S1 已經 commit 之後的最新狀態）會擋下並回
-- LS001，整個 delete_my_account() 呼叫（含它自己的離開家庭動作）跟著回滾——
-- owner 2 需要重試；重試時守門查詢會正確判斷「我現在是唯一成員」，改走「整個
-- 家庭一併刪除」那條路。這正是 migration 檔頭「併發設計」段落描述的自我修復路徑：
-- 沒有死鎖、沒有資料損壞，只是需要重試一次。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_raised boolean := false;
begin
  perform pg_sleep(1.2);

  perform set_config('request.jwt.claims',
    '{"sub":"d4000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  v_t0 := clock_timestamp();
  begin
    perform public.delete_my_account();
  exception when sqlstate 'LS001' then
    v_raised := true;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);
  reset role;

  -- 先定案再斷言：無論成功與否都要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，LS001=%', round(v_elapsed::numeric, 2), v_raised;

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 delete_my_account() 沒有被 S1 阻塞（僅等待 % 秒）——離開家庭那句 DELETE 沒有排到 S1 持有的家庭列鎖後面',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_raised then
    raise exception
      'FAIL 併發：S2 的 delete_my_account() 沒有噴 LS001——owner 1 已經離開，owner 2 自己也離開的話家庭會剩 0 位 owner（永久磚化），既有 owner 不變量 trigger 沒有擋下';
  end if;

  raise notice 'ok 併發：S2 的 delete_my_account() 被阻塞後正確拿到 LS001（需要重試，重試會改走整個家庭一併刪除那條路）';
end;
$$;
