-- LS-206 merge-review R1 m1 — transfer_ownership() 併發測試的場景資料：
-- 一個家庭，owner O、member A、member B。同一位 owner 幾乎同時對兩個不同對象
-- 各發一次 transfer_ownership，用來驗證 migration 檔頭第 2 節「兩句各自的
-- FOR UPDATE（least/greatest user_id 遞增序）」是否真的必要——reviewer 實測：
-- 拿掉這兩句鎖，第二筆會用到過期的 role 判斷，兩人都被錯誤扶正成 owner（見
-- transfer_race_verify.sql 的斷言）。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'de000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'de100000-0000-4000-8000-000000000001',
  'de100000-0000-4000-8000-000000000002',
  'de100000-0000-4000-8000-000000000003'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('de100000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-race-o@ls206.test', now(), now(), '{}', '{}'),
  ('de100000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-race-a@ls206.test', now(), now(), '{}', '{}'),
  ('de100000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-race-b@ls206.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('de100000-0000-4000-8000-000000000001', 'LS206 Race O'),
  ('de100000-0000-4000-8000-000000000002', 'LS206 Race A'),
  ('de100000-0000-4000-8000-000000000003', 'LS206 Race B')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成第一位 owner（O）
insert into public.families (id, name, created_by) values
  ('de000000-0000-4000-8000-000000000001', 'LS206 併發轉移測試家', 'de100000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('de000000-0000-4000-8000-000000000001', 'de100000-0000-4000-8000-000000000002', 'member'),
  ('de000000-0000-4000-8000-000000000001', 'de100000-0000-4000-8000-000000000003', 'member');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.family_members
   where family_id = 'de000000-0000-4000-8000-000000000001';
  if v_n <> 3 then
    raise exception 'SETUP FAIL：LS206 併發轉移測試家應有 3 位成員，實際 %', v_n;
  end if;
  raise notice 'ok setup：LS206 併發轉移測試家（owner O、member A、member B）已就緒';
end;
$$;
