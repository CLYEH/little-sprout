-- LS-320（LS-317 merge-review R2 m4 `a63b98e8`）——「hammer」場景：兩連線各跑
-- 80 回合、順序相反的批次 `set_media_children_batch`，每回合各自 commit，藉由
-- 大量重複來實際重現 m1 那顆鎖序 deadlock，而不只是像 `media_children_race_*`
-- 那樣用固定的 sleep 錯開時序（那組只驗「等待」，抓不到鎖序被拿掉——見
-- `media_children_race_setup.sql` 檔頭「誠實記錄」段，本檔即補這個缺口）。
--
-- 為什麼「hammer」而不是「錯開等待」抓得到：鎖序 deadlock（ABBA 循環等待）需要
-- 兩個連線在各自兩次取鎖**之間**真正交錯，`media_children_race_*` 讓 S1 先把
-- 整批鎖都拿到手才 sleep，S2 因此永遠只會排隊、不會交錯。這裡完全不插入人工
-- sleep，兩個連線各自緊接著跑 80 個「begin → 設定角色 → 呼叫批次 → commit」的
-- 獨立小交易，兩邊速度相近、幾乎同時起跑，80 次裡幾乎必然會撞上幾次「S1 已鎖
-- media1、正要鎖 media2」同時「S2 已鎖 media2、正要鎖 media1」的窗口。
--
-- 偏離票文「set local deadlock_timeout = '20ms'」（見 `_s1.sql` 檔頭）：這裡跑的
-- role `authenticated` 不是超級使用者，`deadlock_timeout` 的 GUC context 是
-- superuser，`set local` 會直接 permission denied；改成全域生效才繞得過去，但
-- 票文「不做」段明訂不改 `deadlock_timeout` 全域設定，依票文為準，維持 Postgres
-- 預設 1 秒偵測延遲——不影響正確性，只是撞上 deadlock 的那一回合多等最多 1 秒
-- 才被 `ON_ERROR_STOP` 中止腳本，80 回合的整體判定結果不受影響。
--
-- 形狀：一個家庭，一位 owner（同時是兩張照片的上傳者）。兩個孩子（X／Y，分別
-- 對應 S1／S2 這一輪要寫入的目標集合，讓 verify 能分辨終態是哪一方贏，而不是
-- 混合）。兩張照片直接寫死 id（兩個連線要對「同一組照片」動作，隨機 id 傳不進
-- 去，以 postgres 身分直接寫表是既有慣例，同 `album_children_race_setup.sql`／
-- `media_children_race_setup.sql`）。初始不標記任何孩子——第一回合就會覆蓋掉。
--
-- S1（`media_children_deadlock_hammer_s1.sql`）：陣列順序 [media1, media2]，每回合
-- 都把兩張照片的標記整組換成 {X}。
-- S2（`media_children_deadlock_hammer_s2.sql`）：陣列順序 [media2, media1]（刻意
-- 反過來），每回合都把兩張照片的標記整組換成 {Y}。
-- 斷言（`media_children_deadlock_hammer_verify.sql`＋`run.sh` 既有的 rc 檢查）：
-- 兩連線 80 回合皆 rc=0（無 40P01）；終態兩張照片標記一致，且是 {X} 或 {Y}
-- 其中一方的完整集合，不會是混合結果。

\set ON_ERROR_STOP on

delete from public.families where id = '63000000-0000-4000-8000-000000000001';
delete from auth.users where id = '63100000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('63100000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'media-children-hammer-owner@ls320.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('63100000-0000-4000-8000-000000000001', '照片孩子標記 hammer 家 owner')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner；owner 同時是本票的建立者
-- 與兩張照片的上傳者，簡化角色矩陣（角色矩陣已在 116_media_children.sql §2 驗過，
-- 這裡只驗鎖序本身）。
insert into public.families (id, name, created_by) values
  ('63000000-0000-4000-8000-000000000001', '照片孩子標記 hammer 家', '63100000-0000-4000-8000-000000000001');

insert into public.children (id, family_id, name, birthday) values
  ('63400000-0000-4000-8000-000000000001', '63000000-0000-4000-8000-000000000001', '孩子X', date '2024-01-01'),
  ('63400000-0000-4000-8000-000000000002', '63000000-0000-4000-8000-000000000001', '孩子Y', date '2024-02-01');

insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('63200000-0000-4000-8000-000000000001', '63000000-0000-4000-8000-000000000001',
   '63000000-0000-4000-8000-000000000001/2026/09/63200000-0000-4000-8000-000000000001.jpg',
   'photo', 400000, now(), 10, 10, '63100000-0000-4000-8000-000000000001'),
  ('63200000-0000-4000-8000-000000000002', '63000000-0000-4000-8000-000000000001',
   '63000000-0000-4000-8000-000000000001/2026/09/63200000-0000-4000-8000-000000000002.jpg',
   'photo', 400000, now(), 10, 10, '63100000-0000-4000-8000-000000000001');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.media_children
   where media_id in ('63200000-0000-4000-8000-000000000001', '63200000-0000-4000-8000-000000000002');
  if v_n <> 0 then
    raise exception 'SETUP FAIL：兩張照片初始應無任何孩子標記，實際 %', v_n;
  end if;
  raise notice 'ok setup：照片孩子標記 hammer 家就緒，兩張照片初始皆無標記';
end;
$$;
