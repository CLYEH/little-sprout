-- LS-58 併發場景「同一人對同一目標雙 toggle_reaction」的場景資料。結構同
-- diary_edit_vs_delete_setup.sql：一個家庭一位成員（同時是唯一 owner），直接寫死
-- 一個 target（相簿）供兩個 session 打同一組參數。

\set ON_ERROR_STOP on

delete from public.families where id = 'f6000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'a1000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('a1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'reaction-race@ls58.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('a1000000-0000-4000-8000-000000000001', '雙 toggle 競態家 唯一成員');

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f6000000-0000-4000-8000-000000000001', '雙 toggle 競態家', 'a1000000-0000-4000-8000-000000000001');

insert into public.albums (id, family_id, title, created_by) values
  ('6c000000-0000-4000-8000-000000000001', 'f6000000-0000-4000-8000-000000000001',
   '雙 toggle 競態相簿', 'a1000000-0000-4000-8000-000000000001');

do $$
declare
  v_owners int;
  v_reactions int;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'f6000000-0000-4000-8000-000000000001' and role = 'owner';
  select count(*) into v_reactions from public.reactions
   where target_type = 'album' and target_id = '6c000000-0000-4000-8000-000000000001';

  if v_owners <> 1 then
    raise exception 'SETUP FAIL：雙 toggle 競態家應有 1 位 owner，實際 %', v_owners;
  end if;
  if v_reactions <> 0 then
    raise exception 'SETUP FAIL：雙 toggle 競態相簿初始應該沒有任何反應，實際 %', v_reactions;
  end if;

  raise notice 'ok setup：雙 toggle 競態家有 1 位 owner，目標相簿初始無反應';
end;
$$;
