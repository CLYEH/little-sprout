-- LS-143 併發測試的場景資料：一個只有「兩位 owner、沒有其他成員」的家庭——跟
-- owner_guard_setup.sql（LS-6／LS-15）同一種形狀，理由相同：owner 不變量的危險
-- 時序需要兩位 owner 同時被移除／離開，單一 owner 的家庭在任何一個 session 內
-- 就會被擋下，測不出 READ COMMITTED 的洞。這裡驗的是同一顆既有 trigger，換成
-- 「兩人幾乎同時呼叫 delete_my_account()」這個新的觸發路徑。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'd3000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'd4000000-0000-4000-8000-000000000001',
  'd4000000-0000-4000-8000-000000000002'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('d4000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls143-owner1@ls143.test', now(), now(), '{}', '{}'),
  ('d4000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls143-owner2@ls143.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('d4000000-0000-4000-8000-000000000001', 'LS143 owner 1'),
  ('d4000000-0000-4000-8000-000000000002', 'LS143 owner 2')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成第一位 owner
insert into public.families (id, name, created_by) values
  ('d3000000-0000-4000-8000-000000000001', 'LS143 併發測試家', 'd4000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('d3000000-0000-4000-8000-000000000001', 'd4000000-0000-4000-8000-000000000002', 'owner');

do $$
declare
  v_members int;
begin
  select count(*) into v_members from public.family_members
   where family_id = 'd3000000-0000-4000-8000-000000000001';
  if v_members <> 2 then
    raise exception 'SETUP FAIL：LS143 併發測試家應有 2 位成員（皆 owner），實際 %', v_members;
  end if;
  raise notice 'ok setup：LS143 併發測試家有 2 位 owner、沒有其他成員';
end;
$$;
