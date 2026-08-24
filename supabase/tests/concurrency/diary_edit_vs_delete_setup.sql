-- LS-48 併發場景「編輯與軟刪同時發生在同一篇日記」的場景資料（merge-reviewer PR #60
-- review F5）。
--
-- 形狀：一個家庭一位 owner、一位 member（作者本人）。日記直接寫死 id（不走
-- create_diary_entry）：兩個 session 要對「同一篇日記」動作，隨機產生的 id 傳不進去，
-- 以 postgres 身分直接寫表是 setup 的正當作法（繞過 RLS，同 approve_reject_race_setup.sql
-- 對 join_requests 的做法）。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原；方向 A 跑完後日記已被
-- 改過內容並軟刪，方向 B 需要一個乾淨的初始狀態）。

\set ON_ERROR_STOP on

delete from public.families where id = 'fg000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'g0000000-0000-4000-8000-000000000001',
  'g0000000-0000-4000-8000-000000000002'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('g0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'g-owner@ls48.test',  now(), now(), '{}', '{}'),
  ('g0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'g-member@ls48.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('g0000000-0000-4000-8000-000000000001', '編輯刪除競態家 owner'),
  ('g0000000-0000-4000-8000-000000000002', '編輯刪除競態家 作者');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('fg000000-0000-4000-8000-000000000001', '編輯刪除競態家', 'g0000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('fg000000-0000-4000-8000-000000000001', 'g0000000-0000-4000-8000-000000000002', 'member');

insert into public.diaries (id, family_id, author_id, body, entry_date) values
  ('5g000000-0000-4000-8000-000000000001', 'fg000000-0000-4000-8000-000000000001',
   'g0000000-0000-4000-8000-000000000002', '原始內容', current_date);

do $$
declare
  v_owners int;
  v_body text;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'fg000000-0000-4000-8000-000000000001' and role = 'owner';
  select d.body, d.deleted_at into v_body, v_deleted from public.diaries d
   where d.id = '5g000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：編輯刪除競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_body <> '原始內容' or v_deleted is not null then
    raise exception 'SETUP FAIL：日記初始狀態不對（body=%，deleted_at=%）', v_body, v_deleted;
  end if;

  raise notice 'ok setup：編輯刪除競態家有 1 位 owner／1 位作者，日記為初始未刪除狀態';
end;
$$;
