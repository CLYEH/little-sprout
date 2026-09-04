-- LS-155 R3 併發測試的場景資料（merge-review R2 `9779da79` R2-M1，N1／N2 兩種
-- 撐窗方式各重現一次 40P01——這裡搬 N2：U1 自己的背景上傳佔另一家庭的 `families`
-- 列鎖，真實行為，不需要人工鎖）。
--
-- U1 是兩個「唯一成員家庭」的唯一成員：家庭 S（family_id 較小，裡面留著早已退出
-- 的 U2 上傳的一張 media）與家庭 S2（family_id 較大，U1 自己的家）。U2 不是 S 的
-- 成員（模擬「早已退出，media 留下」），另有 delete_my_account() 要處理。
--
-- 時序（見 s0／s1／s2）：S0＝U1 自己的背景上傳（真實 INSERT，不是人工鎖）在 S2
-- 送出一張照片、持有交易直到 commit，模擬「上傳交易尚未提交，families(S2) 列鎖
-- 被佔住」這個真實視窗；S1＝U1 的 delete_my_account()（情況 2 依 family_id
-- 遞增序處理 S 再處理 S2，卡在 S2 等 S0）；S2＝U2 的 delete_my_account()（情況
-- 2＋3 合併迴圈處理 S，media-only，需要 family_members(S)——R2 版本這裡會撞上
-- U1 持有的 families(S) 鎖，形成 A-X／X-A 交叉死鎖；R3 修法後 U1 對 S 的第一步
-- 也是 family_members(S)，不會有這個問題，見 verify 的完整說明）。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id in (
  'ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000002'
);
delete from auth.users where id in (
  'ed000000-0000-4000-8000-000000000011',
  'ed000000-0000-4000-8000-000000000012'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('ed000000-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls155-cc4-u1@ls155.test', now(), now(), '{}', '{}'),
  ('ed000000-0000-4000-8000-000000000012', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls155-cc4-u2@ls155.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('ed000000-0000-4000-8000-000000000011', 'LS155 CC4 U1'),
  ('ed000000-0000-4000-8000-000000000012', 'LS155 CC4 U2')
on conflict (id) do update set display_name = excluded.display_name, deletion_requested_at = null;

-- created_by 由 add_creator_as_owner trigger 寫成 U1，兩個家庭都只有 U1 一位成員
insert into public.families (id, name, created_by) values
  ('ed000000-0000-4000-8000-000000000001', 'LS155 CC4 家 S（U1 唯一成員，留有 U2 的 media）', 'ed000000-0000-4000-8000-000000000011'),
  ('ed000000-0000-4000-8000-000000000002', 'LS155 CC4 家 S2（U1 唯一成員，稍後在飛上傳）', 'ed000000-0000-4000-8000-000000000011');

-- U2 早已退出 S（不插入 family_members 列），但留有一張 media
insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('ed000000-0000-4000-8000-000000000021', 'ed000000-0000-4000-8000-000000000001',
   'ed000000-0000-4000-8000-000000000001/2026/08/ed000000-0000-4000-8000-000000000021.jpg',
   'photo', 100, now(), 10, 10, 'ed000000-0000-4000-8000-000000000012');

do $$
declare
  v_members_s int;
  v_members_s2 int;
begin
  select count(*) into v_members_s from public.family_members where family_id = 'ed000000-0000-4000-8000-000000000001';
  select count(*) into v_members_s2 from public.family_members where family_id = 'ed000000-0000-4000-8000-000000000002';
  if v_members_s <> 1 then
    raise exception 'SETUP FAIL：家 S 應該只有 U1 一位成員，實際 %', v_members_s;
  end if;
  if v_members_s2 <> 1 then
    raise exception 'SETUP FAIL：家 S2 應該只有 U1 一位成員，實際 %', v_members_s2;
  end if;
  raise notice 'ok setup：家 S（U1 唯一成員，留有 U2 早已退出的 media）／家 S2（U1 唯一成員，稍後在飛上傳）就緒';
end;
$$;
