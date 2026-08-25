-- LS-52 併發場景「作者編輯內容 與 owner 用 set_comment_deleted 軟刪同時發生在
-- 同一則留言」的場景資料（merge-reviewer PR #70 review F2）。結構同
-- album_edit_vs_delete_setup.sql，這裡不重複展開理由。
--
-- LS-58 更新：原本這裡還建了 f9（作者 a4 也是 owner 的第二個家庭），供「作者搬家
-- vs owner 軟刪」的方向 C 場景使用；comments 收斂成 RPC-only 之後，authenticated
-- 已經沒有任何路徑能搬動一則留言的 family_id，方向 C 場景的前提不再成立，已隨
-- 三個對應檔案一起退役（見 comment_edit_vs_delete_s2_delete.sql 的說明）。這裡
-- 移除 f9 與相關斷言，只保留方向 A／B（編輯先動／軟刪先動）需要的 f4 家庭。

\set ON_ERROR_STOP on

-- f9 不再由本檔建立（LS-58：方向 C 場景已退役，見上方說明），但仍列在刪除清單
-- 裡當清潔動作——舊版本檔案跑過的本機/CI 環境可能留有殘料，先刪乾淨避免下面刪
-- a4/a5 使用者時，cascade 途中撞到 f9 的「家庭必須至少保留一位 owner」不變量。
delete from public.families where id in (
  'f4000000-0000-4000-8000-000000000001',
  'f9000000-0000-4000-8000-000000000001'
);
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
  v_family uuid;
  v_deleted timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f4000000-0000-4000-8000-000000000001' and role = 'owner';
  select c.body, c.family_id, c.deleted_at into v_body, v_family, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：留言競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_body <> '原始留言' or v_family <> 'f4000000-0000-4000-8000-000000000001' or v_deleted is not null then
    raise exception 'SETUP FAIL：留言初始狀態不對（body=%，family_id=%，deleted_at=%）',
      v_body, v_family, v_deleted;
  end if;

  raise notice 'ok setup：留言競態家有 1 位 owner／1 位作者，留言為初始未刪除狀態';
end;
$$;
