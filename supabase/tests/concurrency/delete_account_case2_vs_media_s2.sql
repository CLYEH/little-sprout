-- LS-155 R3 併發場景「情況 2 vs media（N2）」的 session 2。
--
-- U2（早已退出 S、只留有一張 media）3 秒後呼叫 delete_my_account()：合併迴圈把
-- S 當成 media-only 家庭處理，需要 family_members(S)——此刻 S1（U1）可能已經在
-- S 上取過鎖（甚至已經 cascade 刪除，視 S1／S2 交錯的實際時序而定，兩種結果都
-- 正確，見 verify）。R2 版本（情況 2 只鎖 families、不鎖 family_members）這裡
-- 反而會先拿到 family_members(S)（S1 當時完全沒碰它），接著要 families(S) 卡在
-- S1 手上——S1 之後要 cascade 刪 S 需要 family_members(S) 又卡在這裡，互鎖。R3
-- 修法後 S1／S2 對 S 的第一步都是 family_members(S)，先搶到的一方會暢通無阻跑完，
-- 另一方單純排隊。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform pg_sleep(3);

  perform set_config('request.jwt.claims',
    '{"sub":"ed000000-0000-4000-8000-000000000012","role":"authenticated"}', true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
end;
$$;

commit;

\echo 'S2：U2 的 delete_my_account() 已 commit'
