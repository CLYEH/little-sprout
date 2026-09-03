-- LS-143 R2（merge-review R1 m2）併發場景的 session 2：A 在 C 的申請被核准的同時
-- 呼叫 delete_my_account()。
--
-- 這是這組併發測試真正要驗的斷言：A 呼叫的當下，這個家庭是 A 的唯一成員——若
-- delete_my_account() 的「唯一成員」候選判斷沒有正確取鎖重評，會把家庭連同剛核准
-- 的 C 一起 cascade 刪除（m2 描述的原始 bug）。修好之後，S2 必須：
--   1. 被 S1 持有的 FOR KEY SHARE 卡住（`SELECT … FOR UPDATE` 排隊）夠久；
--   2. 解鎖後正常成功（不噴任何例外——family 不再是唯一成員，改走情況 3：軟刪
--      A 自己的內容＋離開家庭，不觸碰 C）。
-- 終態由 delete_account_vs_approve_join_verify.sql 釘死。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_error text := null;
begin
  perform pg_sleep(1.2);

  perform set_config('request.jwt.claims',
    '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  v_t0 := clock_timestamp();
  begin
    perform public.delete_my_account();
  exception when others then
    v_error := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);
  reset role;

  -- 先定案再斷言：無論成功與否都要真的留在資料庫裡，verify 才看得到真正的最終狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，錯誤碼=%', round(v_elapsed::numeric, 2), coalesce(v_error, '（無，成功）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 的 delete_my_account() 沒有被 S1 的 approve_join() 阻塞（僅等待 % 秒）——情況 2 候選家庭的 FOR UPDATE 沒有排到 approve_join() 的 FOR KEY SHARE 後面',
      round(v_elapsed::numeric, 2);
  end if;

  if v_error is not null then
    raise exception
      'FAIL 併發：A 的 delete_my_account() 解鎖後應該正常成功（家庭已經不是唯一成員，該走情況 3），卻拿到錯誤碼 %——若是家庭被連坐 cascade 刪除，這裡不會報錯但 verify 會抓到；這裡報錯代表出現了其他非預期狀況',
      v_error;
  end if;

  raise notice 'ok 併發：S2 的 delete_my_account() 被阻塞後正常成功（改走情況 3，不是連坐 cascade）';
end;
$$;
