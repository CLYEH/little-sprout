-- LS-90 併發場景「兩連線同時呼叫 create_invite」的場景資料。
--
-- 目的：create_invite 的撞碼重試迴圈（unique_violation → 重抽）平常只在單一 session
-- 循序呼叫下被覆蓋（見 supabase/tests/80_join_approval.sql 1、1c、1d 段）；這裡驗的是
-- 兩個真的並行的交易同時對**同一個家庭**呼叫這支 RPC 不會互相干擾——不卡死、不噴出
-- 非預期錯誤、兩邊都拿到合規且互不相同的碼。
--
-- 每個場景開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = '9a000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'ec000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('ec000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ec-owner@ls90.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('ec000000-0000-4000-8000-000000000001', '產碼併發家 owner');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('9a000000-0000-4000-8000-000000000001', '產碼併發家', 'ec000000-0000-4000-8000-000000000001');

do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.invites
   where family_id = '9a000000-0000-4000-8000-000000000001';
  if v_count <> 0 then
    raise exception 'SETUP FAIL：產碼併發家不應該已經有邀請碼（實際 %）', v_count;
  end if;
  raise notice 'ok setup：產碼併發家就緒，owner 待命，尚未有任何邀請碼';
end;
$$;
