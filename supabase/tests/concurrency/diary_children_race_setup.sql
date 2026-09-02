-- LS-121 併發場景「兩個連線同時 update_diary_entry 覆蓋同一篇日記的孩子標記，
-- 目標集合互斥」的場景資料。
--
-- 形狀：一個家庭，一位作者（member）。三個孩子（B／C／D）。日記直接寫死 id、
-- 初始標記寫死成孩子 A（不走 create_diary_entry：兩個 session 要對「同一篇日記」
-- 動作，隨機產生的 id 傳不進去，以 postgres 身分直接寫表是 setup 的正當作法，同
-- diary_edit_vs_delete_setup.sql 對 diaries 本體的既有慣例）。
--
-- S1 把標記整組換成 {B, C}，S2 把標記整組換成 {D}——終態必須是其中一方的完整
-- 集合（後 commit 的那一方），不能是 {B, C, D} 這種混合結果。

\set ON_ERROR_STOP on

delete from public.families where id = 'f8000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'e1000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('e1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'diary-children-race-author@ls121.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('e1000000-0000-4000-8000-000000000001', '孩子標記競態家 作者')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner；作者本人就是 owner，
-- 授權判斷（仍是該家庭 owner/member）因此不受影響，這裡只驗孩子標記本身的競態。
insert into public.families (id, name, created_by) values
  ('f8000000-0000-4000-8000-000000000001', '孩子標記競態家', 'e1000000-0000-4000-8000-000000000001');

insert into public.children (id, family_id, name, birthday) values
  ('28000000-0000-4000-8000-000000000001', 'f8000000-0000-4000-8000-000000000001', '孩子A', date '2024-01-01'),
  ('28000000-0000-4000-8000-000000000002', 'f8000000-0000-4000-8000-000000000001', '孩子B', date '2024-02-01'),
  ('28000000-0000-4000-8000-000000000003', 'f8000000-0000-4000-8000-000000000001', '孩子C', date '2024-03-01'),
  ('28000000-0000-4000-8000-000000000004', 'f8000000-0000-4000-8000-000000000001', '孩子D', date '2024-04-01');

insert into public.diaries (id, family_id, author_id, body, entry_date) values
  ('58000000-0000-4000-8000-000000000001', 'f8000000-0000-4000-8000-000000000001',
   'e1000000-0000-4000-8000-000000000001', '原始內容', current_date);

insert into public.diary_children (family_id, diary_id, child_id) values
  ('f8000000-0000-4000-8000-000000000001', '58000000-0000-4000-8000-000000000001',
   '28000000-0000-4000-8000-000000000001');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.diary_children
   where diary_id = '58000000-0000-4000-8000-000000000001';
  if v_n <> 1 then
    raise exception 'SETUP FAIL：日記初始標記應為 1 個孩子（A），實際 %', v_n;
  end if;
  raise notice 'ok setup：孩子標記競態家就緒，日記初始標記孩子 A';
end;
$$;
