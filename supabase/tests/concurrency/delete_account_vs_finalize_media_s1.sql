-- LS-155 R2 併發場景「media 軟刪 vs finalize_account_deletion」的 session 1。
--
-- U1（家 A 的成員、家 X 留有 media 但不是成員）5 秒後呼叫 delete_my_account()。
-- R1 版本：這裡的 media UPDATE 對家 X 是本交易第一次、也是唯一一次取鎖
-- （families 先、family_members 後），與 S2（finalize，family_members 先、
-- families 後）在家 X／家 A 上互鎖，reviewer 已實測 40P01。R2 修法後，本交易對
-- 每個家庭都先鎖整個 family_members（family_id 遞增序，X 在 A 之前）才碰
-- families，與 S2 的鎖序一致，只會排隊、不會死鎖——這裡預期成功完成（可能等待
-- 一段時間，但不應該收到任何錯誤）。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform pg_sleep(5);

  perform set_config('request.jwt.claims',
    '{"sub":"e8000000-0000-4000-8000-000000000013","role":"authenticated"}', true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
end;
$$;

commit;

\echo 'S1：U1 的 delete_my_account() 已 commit'
