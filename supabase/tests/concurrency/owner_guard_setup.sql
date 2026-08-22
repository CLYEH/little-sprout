-- LS-6 併發測試的場景資料：一個有「兩位 owner」的家庭。
--
-- 這個形狀是刻意的：owner 不變量的危險時序需要兩位 owner 同時被降級／移除，
-- 單一 owner 的家庭在任何一個 session 內就會被擋下，測不出 READ COMMITTED 的洞。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'fd000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000002'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('d0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'd-owner1@ls6.test', now(), now(), '{}', '{}'),
  ('d0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'd-owner2@ls6.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('d0000000-0000-4000-8000-000000000001', 'D 家 owner 1'),
  ('d0000000-0000-4000-8000-000000000002', 'D 家 owner 2');

-- created_by 由 add_creator_as_owner trigger 寫成第一位 owner
insert into public.families (id, name, created_by) values
  ('fd000000-0000-4000-8000-000000000001', '併發測試家', 'd0000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('fd000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002', 'owner');

do $$
declare
  v_owners int;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'fd000000-0000-4000-8000-000000000001' and role = 'owner';
  if v_owners <> 2 then
    raise exception 'SETUP FAIL：併發測試家應有 2 位 owner，實際 %', v_owners;
  end if;
  raise notice 'ok setup：併發測試家有 2 位 owner';
end;
$$;
