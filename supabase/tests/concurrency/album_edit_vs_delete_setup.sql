-- LS-52 併發場景「作者直接 UPDATE 內容 與 owner 用 set_album_deleted 軟刪同時發生在
-- 同一本相簿」的場景資料（merge-reviewer PR #70 review F2；第 2 輪 review N1 追加
-- 「作者搬家 vs owner 軟刪」場景，需要第二個家庭 f8 讓作者搬得過去）。
--
-- 形狀比照 diary_edit_vs_delete_setup.sql：一個家庭一位 owner、一位 member（作者
-- 本人）。相簿直接寫死 id（不走 RPC 新增，albums 沒有 create RPC），以 postgres
-- 身分直接寫表是 setup 的正當作法（繞過 RLS，同 approve_reject_race_setup.sql 對
-- join_requests 的做法）。
--
-- f8：作者（a6）也是 owner 的第二個家庭——`albums_update` policy 的建立者分支允許
-- 建立者把自己的相簿搬到自己也是 contributor 的另一個家庭（`family_id in
-- contributor_family_ids()`，這件事本身該不該被允許是 LS-57 的產品問題，不在本票
-- 展開），這裡只是借用這個既有行為，架出「作者搬家 vs owner 軟刪」的併發場景。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原；先刪 f3 與 f8
-- 兩個家庭，涵蓋「上一輪把相簿搬到 f8 之後測試才失敗中斷」的殘留狀態，不能只刪 f3）。

\set ON_ERROR_STOP on

delete from public.families where id in (
  'f3000000-0000-4000-8000-000000000001',
  'f8000000-0000-4000-8000-000000000001'
);
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

-- f8：作者 a6 自己開的另一個家庭，自動成為它的 owner（add_creator_as_owner trigger）——
-- 讓 a6 在 f8 也是 contributor，才搬得動相簿過去。
insert into public.families (id, name, created_by) values
  ('f8000000-0000-4000-8000-000000000001', '相簿競態家（搬家目的地）', 'a6000000-0000-4000-8000-000000000001');

insert into public.albums (id, family_id, title, created_by) values
  ('49000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000001',
   '原始標題', 'a6000000-0000-4000-8000-000000000001');

do $$
declare
  v_owners int;
  v_a6_owns_f8 boolean;
  v_title text;
  v_family uuid;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f3000000-0000-4000-8000-000000000001' and role = 'owner';
  select exists (
    select 1 from public.family_members
     where family_id = 'f8000000-0000-4000-8000-000000000001'
       and user_id = 'a6000000-0000-4000-8000-000000000001' and role = 'owner'
  ) into v_a6_owns_f8;
  select a.title, a.family_id, a.deleted_at into v_title, v_family, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：相簿競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if not v_a6_owns_f8 then
    raise exception 'SETUP FAIL：作者 a6 應該是 f8（搬家目的地）的 owner';
  end if;
  if v_title <> '原始標題' or v_family <> 'f3000000-0000-4000-8000-000000000001' or v_deleted is not null then
    raise exception 'SETUP FAIL：相簿初始狀態不對（title=%，family_id=%，deleted_at=%）',
      v_title, v_family, v_deleted;
  end if;

  raise notice 'ok setup：相簿競態家有 1 位 owner／1 位作者（同時是 f8 的 owner），相簿為初始未刪除、未搬家狀態';
end;
$$;
