-- LS-317 merge-review R1 m2（a0a811c6）併發場景「兩個順序相反的重疊批次同時
-- set_media_children_batch」的場景資料。
--
-- 為什麼要另開一組（不能只靠 album_children_race）：本票的 `set_media_children_
-- batch`（supabase/migrations/20260917155738_media_children.sql:252-289）在單一
-- 交易內對呼叫端給定的多筆 media 逐一取 `for update` 鎖，R1 版本依陣列給定順序
-- 逐筆處理，reviewer 已實測兩個順序相反的重疊批次會構成 ABBA 循環等待（40P01）；
-- R2 修法後改依 media_id 排序取鎖。這裡驗的是批次（兩筆 media 一次覆蓋），不是
-- 單筆 set_media_children，跟 diary/album 的單資源覆蓋場景不是同一顆函式。
--
-- 誠實記錄本組測試的限度（LS-320 已補回歸保護，見下）：這裡沿用
-- album_children_race 的既定手法（S1 完整跑完整個批次呼叫、持鎖 sleep 3 秒；
-- S2 晚 1.2 秒才動）來讓終態斷言穩定可重現，只有「等待」沒有「交錯」，抓不到
-- m1 那顆 order by 被拿掉——ABBA 循環等待需要兩個連線在各自兩次取鎖之間真正
-- 交錯，固定的 sleep 錯開時序做不到（merge-review R2 `a63b98e8` m4 已實測：拿掉
-- order by 重跑這組，仍然全綠）。m1 修法「改前 deadlock、改後皆成功」的直接證據
-- 現在是機械化的 `media_children_deadlock_hammer_*` 場景（LS-320，run.sh 同檔
-- 緊接在這組之後註冊）：兩連線各跑 80 回合、陣列順序相反、不插入人工 sleep，靠
-- 大量重複製造交錯窗口，並把 deadlock_timeout 縮到 20ms 加速偵測；mutation 自證
-- （拿掉 order by 重跑、觀察 40P01；改回後重跑、觀察兩邊皆成功）見該票 PR
-- handoff。這一組（`media_children_race_*`）保留，驗的仍是「等待後終態一致」，
-- 兩組合起來才是完整的回歸保護：批次無論呼叫端陣列順序為何，重疊批次不出錯、
-- 終態乾淨是後 commit 那一方的完整集合，不會混合。
--
-- 形狀：一個家庭，一位 owner（同時是兩張照片的上傳者，簡化角色矩陣——角色矩陣
-- 已在 116_media_children.sql §2 驗過）。三個孩子（B／C／D）。兩張照片直接寫死 id
-- （兩個 session 要對「同一組照片」動作，隨機產生的 id 傳不進去，以 postgres 身分
-- 直接寫表是 setup 的正當作法，同 album_children_race_setup.sql 的既有慣例）。
-- 初始兩張照片都標記孩子 B。
--
-- S1 把兩張照片的標記都整組換成 {C}（呼叫端陣列順序：media2 在前、media1 在後，
-- 刻意倒著給），S2 把兩張照片的標記都整組換成 {D}（呼叫端陣列順序：media1 在前、
-- media2 在後，正常順序）——終態必須是兩張照片都是其中一方的完整集合（後 commit
-- 的那一方），不能是混合結果，兩個 session 也都必須以 rc=0 結束（沒有 40P01）。

\set ON_ERROR_STOP on

delete from public.families where id = 'ba000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'bb000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('bb000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'media-children-race-owner@ls317.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('bb000000-0000-4000-8000-000000000001', '照片孩子標記競態家 owner')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner。
insert into public.families (id, name, created_by) values
  ('ba000000-0000-4000-8000-000000000001', '照片孩子標記競態家', 'bb000000-0000-4000-8000-000000000001');

insert into public.children (id, family_id, name, birthday) values
  ('bc000000-0000-4000-8000-000000000001', 'ba000000-0000-4000-8000-000000000001', '孩子B', date '2024-01-01'),
  ('bc000000-0000-4000-8000-000000000002', 'ba000000-0000-4000-8000-000000000001', '孩子C', date '2024-02-01'),
  ('bc000000-0000-4000-8000-000000000003', 'ba000000-0000-4000-8000-000000000001', '孩子D', date '2024-03-01');

insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('bd000000-0000-4000-8000-000000000001', 'ba000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001/2026/09/bd000000-0000-4000-8000-000000000001.jpg',
   'photo', 400000, now(), 10, 10, 'bb000000-0000-4000-8000-000000000001'),
  ('bd000000-0000-4000-8000-000000000002', 'ba000000-0000-4000-8000-000000000001',
   'ba000000-0000-4000-8000-000000000001/2026/09/bd000000-0000-4000-8000-000000000002.jpg',
   'photo', 400000, now(), 10, 10, 'bb000000-0000-4000-8000-000000000001');

insert into public.media_children (family_id, media_id, child_id) values
  ('ba000000-0000-4000-8000-000000000001', 'bd000000-0000-4000-8000-000000000001',
   'bc000000-0000-4000-8000-000000000001'),
  ('ba000000-0000-4000-8000-000000000001', 'bd000000-0000-4000-8000-000000000002',
   'bc000000-0000-4000-8000-000000000001');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.media_children
   where media_id in ('bd000000-0000-4000-8000-000000000001', 'bd000000-0000-4000-8000-000000000002');
  if v_n <> 2 then
    raise exception 'SETUP FAIL：兩張照片初始標記應各為孩子 B（共 2 列），實際 %', v_n;
  end if;
  raise notice 'ok setup：照片孩子標記競態家就緒，兩張照片初始都標記孩子 B';
end;
$$;
