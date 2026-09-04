-- LS-155 R3 併發場景「情況 2 vs media（N2）」的 session 1。
--
-- U1（S、S2 皆唯一成員）1 秒後呼叫 delete_my_account()：R3 合併迴圈依 family_id
-- 遞增序處理——S 先（無阻塞，cascade 刪除，連帶清掉 U2 早已退出留下的 media）、
-- S2 後（需要 families(S2) 鎖，被 S0 的在飛上傳擋住，直到第 9 秒）。R2 版本（情況
-- 2 迴圈外、只鎖 families 不鎖 family_members）在這裡會與 S2（U2 的
-- delete_my_account()）互鎖；R3 修法後 S 的第一步就是 family_members(S)，跟 S2
-- session（同樣先搶 family_members(S)）只會排隊、不會循環等待。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform pg_sleep(1);

  perform set_config('request.jwt.claims',
    '{"sub":"ed000000-0000-4000-8000-000000000011","role":"authenticated"}', true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
end;
$$;

commit;

\echo 'S1：U1 的 delete_my_account() 已 commit'
