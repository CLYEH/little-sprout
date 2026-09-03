-- LS-143 R2（merge-review R1 m2）併發場景「approve_join 先動、delete_my_account
-- 後動」的 session 1：A 核准 C 的加入申請。role=owner，核准後家庭會有 A、C 兩位
-- owner。approve_join 本身的 INSERT INTO family_members 會因為 FK 參照完整性
-- 檢查對 families 那一列取 FOR KEY SHARE（見 migration 檔頭「併發設計」）——
-- pg_sleep(3) 讓這個交易（含它持有的 FOR KEY SHARE）保持開著，給 S2 的
-- delete_my_account() 一個真的會被擋住的窗口。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"d6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  perform public.approve_join('d9000000-0000-4000-8000-000000000001');
  reset role;
end;
$$;

select pg_sleep(3);

commit;

\echo 'S1：A 的 approve_join() 已 commit'
