-- LS-121 R2（merge-reviewer PR #218 review M2）併發場景「兩個連線同時 set_album_
-- children 覆蓋同一本相簿的孩子標記，目標集合互斥」的場景資料。
--
-- 為什麼要另開一組（不能只靠 diary_children_race）：`set_album_children`
-- （supabase/migrations/20260902011514_diary_album_multi_child_tags.sql:576-604）
-- 完全沒有對 `albums` 下 UPDATE——`select a.* into v_album from public.albums a
-- where a.id = p_album_id for update` 是兩個並行覆蓋呼叫之間**唯一**的序列化手段
-- （不像 `update_diary_entry` 那樣還有一句 `update diaries set body = ...` 自己
-- 順便取到列鎖）。這把鎖被拿掉時，diary 那組 race 測試量不到差異（見
-- `diary_children_race_s2.sql` 檔頭的誠實歸因說明）；這組的終態檢查
-- （`album_children_race_verify.sql`）會——但 S2 自己的等待秒數斷言不會，兩者
-- 分辨不同事情，細節見 `album_children_race_s2.sql` 檔頭，mutation 實測數字見
-- PR handoff。
--
-- 形狀：一個家庭，一位 owner（同時是相簿建立者，簡化角色矩陣，本組只驗鎖本身，
-- 角色矩陣已在 97_multi_child_tags.sql §2 驗過）。三個孩子（B／C／D）。相簿直接
-- 寫死 id（不走 albums 的 .insert()：兩個 session 要對「同一本相簿」動作，隨機
-- 產生的 id 傳不進去，以 postgres 身分直接寫表是 setup 的正當作法，同
-- diary_children_race_setup.sql 對 diaries 本體的既有慣例）。初始標記孩子 A。
--
-- S1 把標記整組換成 {B, C}，S2 把標記整組換成 {D}——終態必須是其中一方的完整
-- 集合（後 commit 的那一方），不能是 {B, C, D} 這種混合結果。

\set ON_ERROR_STOP on

delete from public.families where id = 'f0000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'e2000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('e2000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'album-children-race-owner@ls121.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('e2000000-0000-4000-8000-000000000001', '相簿孩子標記競態家 owner')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner；owner 同時是本票的建立者，
-- 授權判斷（仍是該家庭 owner/member 的建立者本人）因此不受影響，這裡只驗孩子標記
-- 本身的競態。
insert into public.families (id, name, created_by) values
  ('f0000000-0000-4000-8000-000000000001', '相簿孩子標記競態家', 'e2000000-0000-4000-8000-000000000001');

insert into public.children (id, family_id, name, birthday) values
  ('2e000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', '孩子A', date '2024-01-01'),
  ('2e000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000001', '孩子B', date '2024-02-01'),
  ('2e000000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000001', '孩子C', date '2024-03-01'),
  ('2e000000-0000-4000-8000-000000000004', 'f0000000-0000-4000-8000-000000000001', '孩子D', date '2024-04-01');

insert into public.albums (id, family_id, title, created_by) values
  ('4f000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001',
   '原始相簿', 'e2000000-0000-4000-8000-000000000001');

insert into public.album_children (family_id, album_id, child_id) values
  ('f0000000-0000-4000-8000-000000000001', '4f000000-0000-4000-8000-000000000001',
   '2e000000-0000-4000-8000-000000000001');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.album_children
   where album_id = '4f000000-0000-4000-8000-000000000001';
  if v_n <> 1 then
    raise exception 'SETUP FAIL：相簿初始標記應為 1 個孩子（A），實際 %', v_n;
  end if;
  raise notice 'ok setup：相簿孩子標記競態家就緒，相簿初始標記孩子 A';
end;
$$;
