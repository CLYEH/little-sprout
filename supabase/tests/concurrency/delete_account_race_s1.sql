-- LS-143 併發場景「兩位共同 owner 同時刪除帳號」的 session 1。
--
-- owner 1 呼叫 delete_my_account()：家庭有共同 owner（owner 2）、沒有其他成員，
-- 所以既不會被 LS050 擋下（不是唯一 owner），也不會走「唯一成員刪整個家庭」那條
-- 路（owner 2 還在）——正常軟刪（沒有內容可刪，no-op）＋離開家庭。離開家庭那句
-- DELETE 會觸發既有的 private.enforce_family_has_owner() trigger，取得
-- d3000000-...-001 這個家庭列的 FOR NO KEY UPDATE 鎖，一路持有到 COMMIT——
-- pg_sleep(3) 讓 S2 有機會在這段期間撞上同一把鎖。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"d4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
end;
$$;

select pg_sleep(3);

commit;

\echo 'S1：owner 1 的 delete_my_account() 已 commit'
