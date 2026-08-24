-- LS-52 併發場景「作者直接 UPDATE 內容 與 owner 用 set_comment_deleted 軟刪同時
-- 發生在同一則留言」的場景資料（merge-reviewer PR #70 review F2）。結構同
-- album_edit_vs_delete_setup.sql，這裡不重複展開理由。

\set ON_ERROR_STOP on

delete from public.families where id = 'f4000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'a5000000-0000-4000-8000-000000000001',
  'a4000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('a5000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'comment-race-owner@ls52.test',  now(), now(), '{}', '{}'),
  ('a4000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'comment-race-member@ls52.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('a5000000-0000-4000-8000-000000000001', '留言競態家 owner'),
  ('a4000000-0000-4000-8000-000000000001', '留言競態家 作者');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f4000000-0000-4000-8000-000000000001', '留言競態家', 'a5000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('f4000000-0000-4000-8000-000000000001', 'a4000000-0000-4000-8000-000000000001', 'member');

-- target_type/target_id 是多型關聯、DB 不下外鍵（見 docs/API.md §3 comments 段），
-- 這裡的 target_id 不必真的指向一筆存在的列，不影響本場景要驗的東西。
insert into public.comments (id, family_id, target_type, target_id, author_id, body) values
  ('69000000-0000-4000-8000-000000000001', 'f4000000-0000-4000-8000-000000000001',
   'album', gen_random_uuid(), 'a4000000-0000-4000-8000-000000000001', '原始留言');

do $$
declare
  v_owners int;
  v_body text;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f4000000-0000-4000-8000-000000000001' and role = 'owner';
  select c.body, c.deleted_at into v_body, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：留言競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_body <> '原始留言' or v_deleted is not null then
    raise exception 'SETUP FAIL：留言初始狀態不對（body=%，deleted_at=%）', v_body, v_deleted;
  end if;

  raise notice 'ok setup：留言競態家有 1 位 owner／1 位作者，留言為初始未刪除狀態';
end;
$$;
