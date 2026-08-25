-- LS-57 併發場景「owner 軟刪 vs 作者同時嘗試還原」的場景資料。
--
-- 形狀比照 diary_edit_vs_delete_setup.sql：一個家庭一位 owner、一位 member（作者
-- 本人）。日記直接寫死 id（不走 create_diary_entry）：兩個 session 要對「同一篇
-- 日記」動作，隨機產生的 id 傳不進去，以 postgres 身分直接寫表是 setup 的正當
-- 作法（繞過 RLS，同 diary_edit_vs_delete_setup.sql 對 diaries 的做法）。
--
-- 日記一開始是**未刪除**狀態（不是預先軟刪好的）——S1（owner）在這個場景裡負責
-- 「第一次」軟刪，S2（作者）在 S1 commit 之前就發出還原呼叫。這樣才測得到
-- `for update` 鎖真正必要的地方：S2 的還原判斷必須讀到 S1 commit 之後的
-- deleted_by，而不是這個 setup 檔案原本就寫死的舊值。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'f7000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'd1000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('d1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'delete-restore-race-owner@ls57.test',  now(), now(), '{}', '{}'),
  ('d2000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'delete-restore-race-member@ls57.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('d1000000-0000-4000-8000-000000000001', '軟刪還原競態家 owner'),
  ('d2000000-0000-4000-8000-000000000001', '軟刪還原競態家 作者');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f7000000-0000-4000-8000-000000000001', '軟刪還原競態家', 'd1000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('f7000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'member');

insert into public.diaries (id, family_id, author_id, body, entry_date) values
  ('57000000-0000-4000-8000-000000000001', 'f7000000-0000-4000-8000-000000000001',
   'd2000000-0000-4000-8000-000000000001', '原始內容', current_date);

do $$
declare
  v_owners int;
  v_body text;
  v_deleted timestamptz;
  v_deleted_by uuid;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f7000000-0000-4000-8000-000000000001' and role = 'owner';
  select d.body, d.deleted_at, d.deleted_by into v_body, v_deleted, v_deleted_by from public.diaries d
   where d.id = '57000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：軟刪還原競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_body <> '原始內容' or v_deleted is not null or v_deleted_by is not null then
    raise exception 'SETUP FAIL：日記初始狀態不對（body=%，deleted_at=%，deleted_by=%）',
      v_body, v_deleted, v_deleted_by;
  end if;

  raise notice 'ok setup：軟刪還原競態家有 1 位 owner／1 位作者，日記為初始未刪除狀態';
end;
$$;
