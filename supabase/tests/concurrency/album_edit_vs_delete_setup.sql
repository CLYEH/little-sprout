-- LS-52 併發場景「作者直接 UPDATE 內容 與 owner 用 set_album_deleted 軟刪同時發生在
-- 同一本相簿」的場景資料（merge-reviewer PR #70 review F2）。
--
-- 形狀比照 diary_edit_vs_delete_setup.sql：一個家庭一位 owner、一位 member（作者
-- 本人）。相簿直接寫死 id（不走 RPC 新增，albums 沒有 create RPC），以 postgres
-- 身分直接寫表是 setup 的正當作法（繞過 RLS，同 approve_reject_race_setup.sql 對
-- join_requests 的做法）。
--
-- LS-57：這個檔案原本還多建一個家庭 f8，讓作者（a6）能把自己的相簿直接 UPDATE
-- 搬過去，架出「作者搬家 vs owner 軟刪」的併發場景（第 2 輪 review N1 追加）。
-- LS-57 把 `family_id` 收斂成不可變欄之後，這條「搬家」路徑本身已經不存在
-- （直接 UPDATE 改 `family_id` 一律 `42501`），對應的場景與 f8 這個第二家庭一併
-- 隨本票退役——見 `supabase/tests/run.sh` 對應段落的說明，f8 的 fixture 不再需要。
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

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('a7000000-0000-4000-8000-000000000001', '相簿競態家 owner'),
  ('a6000000-0000-4000-8000-000000000001', '相簿競態家 作者')
on conflict (id) do update set display_name = excluded.display_name;

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
  v_family uuid;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f3000000-0000-4000-8000-000000000001' and role = 'owner';
  select a.title, a.family_id, a.deleted_at into v_title, v_family, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：相簿競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_title <> '原始標題' or v_family <> 'f3000000-0000-4000-8000-000000000001' or v_deleted is not null then
    raise exception 'SETUP FAIL：相簿初始狀態不對（title=%，family_id=%，deleted_at=%）',
      v_title, v_family, v_deleted;
  end if;

  raise notice 'ok setup：相簿競態家有 1 位 owner／1 位作者，相簿為初始未刪除狀態';
end;
$$;
