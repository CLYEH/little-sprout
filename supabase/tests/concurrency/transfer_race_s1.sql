-- LS-206 merge-review R1 m1 併發場景「owner 幾乎同時對兩個不同對象各發一次
-- transfer_ownership」的 session 1。
--
-- O 呼叫 transfer_ownership(family, A)：兩句 FOR UPDATE 依 least/greatest(O, A)
-- 遞增序鎖住 O 與 A 兩列，成功把 A 升為 owner、O 降為 member。pg_sleep(3) 讓
-- S2 有機會在 O 這一列的鎖釋放前撞上（S2 轉移的對象是 B，但 least/greatest(O, B)
-- 一樣包含 O，兩筆呼叫都要先鎖到 O 這一列）。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"de100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  perform public.transfer_ownership(
    'de000000-0000-4000-8000-000000000001', 'de100000-0000-4000-8000-000000000002');
  reset role;
end;
$$;

select pg_sleep(3);

commit;

\echo 'S1：O 轉移給 A 的 transfer_ownership() 已 commit'
