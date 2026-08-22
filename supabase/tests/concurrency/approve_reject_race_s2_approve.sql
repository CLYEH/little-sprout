-- 併發場景二（方向 B：拒絕先動）的 session 2：爸爸在媽媽還沒 commit 的時候按下核准。
--
-- 這個方向驗的是 **approve_join 的 `for update`**。沒有那把鎖的話：
--   爸爸讀到 status 還是 pending（媽媽未 commit）→ 通過狀態檢查 → 把申請人寫進
--   family_members（這一步不會被任何鎖擋住，那是一列全新的成員資料）→ 最後才在
--   UPDATE join_requests 上排隊，等到之後把 status 蓋成 approved。
-- 結果是媽媽的拒絕被無聲地推翻，而且她不會收到任何錯誤——她以為自己擋下了這個人。
-- 「拒絕後無殘留權限」在這個時序下就是這樣破掉的。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls015 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"eb000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 reject_join（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.approve_join('9f000000-0000-4000-8000-000000000001');
  exception
    when sqlstate 'LS015' then v_ls015 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：沒被擋下的核准要真的留在資料庫裡，verify 才看得到「被拒絕的人進了家庭」
  commit;

  raise notice 'S2：等待 % 秒後結束，LS015=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls015, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：爸爸的核准沒有被媽媽的拒絕阻塞（僅等待 % 秒）—— approve_join 沒有對申請列取鎖',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls015 then
    raise exception
      'FAIL 併發：已被拒絕的申請竟然還能核准（錯誤碼 %）—— 媽媽的拒絕被無聲推翻，被拒絕的人進到家庭裡',
      coalesce(v_other, '沒有任何錯誤');
  end if;

  raise notice 'ok 併發：爸爸的核准被阻塞後拿到 LS015';
end;
$$;
