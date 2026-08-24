-- LS-52 併發場景「作者直接 UPDATE 內容 與 owner 用 set_album_deleted 軟刪同時發生在
-- 同一本相簿」的場景資料（merge-reviewer PR #70 review F2）。
--
-- 形狀比照 diary_edit_vs_delete_setup.sql：一個家庭一位 owner、一位 member（作者
-- 本人）。相簿直接寫死 id（不走 RPC 新增，albums 沒有 create RPC），以 postgres
-- 身分直接寫表是 setup 的正當作法（繞過 RLS，同 approve_reject_race_setup.sql 對
-- join_requests 的做法）。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'f3000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'a7000000-0000-4000-8000-000000000001',
  'a6000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('a7000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'album-race-owner@ls52.test',  now(), now(), '{}', '{}'),
  ('a6000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'album-race-member@ls52.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('a7000000-0000-4000-8000-000000000001', '相簿競態家 owner'),
  ('a6000000-0000-4000-8000-000000000001', '相簿競態家 作者');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f3000000-0000-4000-8000-000000000001', '相簿競態家', 'a7000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('f3000000-0000-4000-8000-000000000001', 'a6000000-0000-4000-8000-000000000001', 'member');

insert into public.albums (id, family_id, title, created_by) values
  ('49000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001',
   '原始標題', 'a6000000-0000-4000-8000-000000000001');

do $$
declare
  v_owners int;
  v_title text;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f3000000-0000-4000-8000-000000000001' and role = 'owner';
  select a.title, a.deleted_at into v_title, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：相簿競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_title <> '原始標題' or v_deleted is not null then
    raise exception 'SETUP FAIL：相簿初始狀態不對（title=%，deleted_at=%）', v_title, v_deleted;
  end if;

  raise notice 'ok setup：相簿競態家有 1 位 owner／1 位作者，相簿為初始未刪除狀態';
end;
$$;
