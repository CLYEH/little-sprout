-- 併發場景二（方向 A：核准先動）的 session 2：媽媽在爸爸還沒 commit 的時候按下拒絕。
--
-- 這個方向驗的是 **reject_join 的 `for update`**（方向 B 才驗 approve_join 那一把，
-- 見 approve_reject_race_s2_approve.sql——兩個方向缺一不可，是 mutation test 逼出來的：
-- 只跑這個方向的話，把 approve_join 的鎖拿掉測試仍然是綠的，因為先動的那一邊
-- 反正會在自己的 UPDATE 上取到列鎖）。
--
-- 兩條斷言：
--   1. 必須「被阻塞」——reject_join 先對申請列取 `for update`，同一筆申請的審核才會排隊。
--   2. 解除阻塞後必須噴 LS015（申請不存在或已被處理）：READ COMMITTED 下取得列鎖之後
--      會重讀最新列版本，讀到的 status 已經是 approved，被函式裡的狀態檢查擋下。
--
-- 沒有那把鎖的話，媽媽會讀到 pending 而往下走，最後把 status 蓋成 rejected——
-- 但爸爸寫進去的 family_members 那一列還在。最終狀態的矛盾由
-- approve_reject_race_verify_approved.sql 直接斷言（那才是「殘留權限」的實際後果）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
  v_ls015 boolean := false;
  v_other text := null;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"eb000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 approve_join（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  begin
    perform public.reject_join('9f000000-0000-4000-8000-000000000001');
  exception
    when sqlstate 'LS015' then v_ls015 := true;
    when others then v_other := sqlstate;
  end;
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  -- 先定案再斷言：沒被擋下的拒絕要真的留在資料庫裡，verify 才看得到矛盾狀態
  commit;

  raise notice 'S2：等待 % 秒後結束，LS015=%，其他錯誤碼=%',
    round(v_elapsed::numeric, 2), v_ls015, coalesce(v_other, '（無）');

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：媽媽的拒絕沒有被爸爸的核准阻塞（僅等待 % 秒）—— 同一筆申請的審核沒有序列化',
      round(v_elapsed::numeric, 2);
  end if;

  if not v_ls015 then
    raise exception
      'FAIL 併發：已被核准的申請竟然還能被拒絕（錯誤碼 %）—— 成員已寫入、狀態卻變成 rejected',
      coalesce(v_other, '沒有任何錯誤');
  end if;

  raise notice 'ok 併發：媽媽的拒絕被阻塞後拿到 LS015';
end;
$$;
