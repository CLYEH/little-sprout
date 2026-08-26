-- LS-66 併發場景「編輯與軟刪同時發生在同一個孩子檔案」的場景資料，理由與
-- diary_edit_vs_delete_setup.sql（LS-48）同型：owner 用 set_child_deleted 軟刪 vs
-- member 用 update_child 編輯，兩者都要對同一列取 `for update`，才能保證序列化。
--
-- 形狀：一個家庭一位 owner、一位 member。孩子直接寫死 id（不走 create_child）：
-- 兩個 session 要對「同一個孩子檔案」動作，隨機產生的 id 傳不進去，以 postgres 身分
-- 直接寫表是 setup 的正當作法（繞過 RLS，同 diary_edit_vs_delete_setup.sql 的做法）。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'f5000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'a2000000-0000-4000-8000-000000000001',
  'a3000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('a2000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'child-race-owner@ls66.test',  now(), now(), '{}', '{}'),
  ('a3000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'child-race-member@ls66.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('a2000000-0000-4000-8000-000000000001', '編輯刪除競態家 owner'),
  ('a3000000-0000-4000-8000-000000000001', '編輯刪除競態家 member')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f5000000-0000-4000-8000-000000000001', '孩子編輯刪除競態家', 'a2000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('f5000000-0000-4000-8000-000000000001', 'a3000000-0000-4000-8000-000000000001', 'member');

insert into public.children (id, family_id, name, birthday) values
  ('29000000-0000-4000-8000-000000000001', 'f5000000-0000-4000-8000-000000000001', '原始名字', date '2025-01-01');

do $$
declare
  v_owners int;
  v_name text;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f5000000-0000-4000-8000-000000000001' and role = 'owner';
  select c.name, c.deleted_at into v_name, v_deleted from public.children c
   where c.id = '29000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：孩子編輯刪除競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_name <> '原始名字' or v_deleted is not null then
    raise exception 'SETUP FAIL：孩子檔案初始狀態不對（name=%，deleted_at=%）', v_name, v_deleted;
  end if;

  raise notice 'ok setup：孩子編輯刪除競態家有 1 位 owner／1 位 member，孩子檔案為初始未刪除狀態';
end;
$$;
