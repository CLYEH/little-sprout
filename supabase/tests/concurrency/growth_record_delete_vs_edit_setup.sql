-- LS-419（池 `9402ad1b`，來源 LS-258 R1 minor-3）併發場景「owner 軟刪與作者編輯同時發生在
-- 同一筆成長紀錄」的場景資料。形狀比照 diary_edit_vs_delete_setup.sql。
--
-- 形狀：一個家庭一位 owner、一位 member（作者本人）、一個孩子。紀錄直接寫死 id（不走
-- upsert_growth_record）：兩個 session 要對「同一筆紀錄」動作，隨機產生的 id 傳不進去，
-- 以 postgres 身分直接寫表是 setup 的正當作法（繞過 RLS，同 diary_edit_vs_delete_setup.sql）。

\set ON_ERROR_STOP on

delete from public.families where id = '74000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  '75000000-0000-4000-8000-000000000001',
  '75000000-0000-4000-8000-000000000002'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('75000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'growth-race-owner@ls419.test',  now(), now(), '{}', '{}'),
  ('75000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'growth-race-member@ls419.test', now(), now(), '{}', '{}');

-- auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('75000000-0000-4000-8000-000000000001', '成長紀錄競態家 owner'),
  ('75000000-0000-4000-8000-000000000002', '成長紀錄競態家 作者')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('74000000-0000-4000-8000-000000000001', '成長紀錄競態家', '75000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('74000000-0000-4000-8000-000000000001', '75000000-0000-4000-8000-000000000002', 'member');

insert into public.children (id, family_id, name, birthday) values
  ('76000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000001',
   '競態寶寶', date '2025-01-01');

insert into public.growth_records (id, family_id, child_id, author_id, measured_on, height_cm, note)
values
  ('77000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000001',
   '76000000-0000-4000-8000-000000000001', '75000000-0000-4000-8000-000000000002',
   current_date, 70.0, '原始備註');

do $$
declare
  v_owners int;
  v_note text;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = '74000000-0000-4000-8000-000000000001' and role = 'owner';
  select g.note, g.deleted_at into v_note, v_deleted from public.growth_records g
   where g.id = '77000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：成長紀錄競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_note is distinct from '原始備註' or v_deleted is not null then
    raise exception 'SETUP FAIL：成長紀錄初始狀態不對（note=%，deleted_at=%）', v_note, v_deleted;
  end if;

  raise notice 'ok setup：成長紀錄競態家有 1 位 owner／1 位作者，紀錄為初始未刪除狀態';
end;
$$;
