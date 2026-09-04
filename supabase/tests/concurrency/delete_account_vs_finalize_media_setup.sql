-- LS-155 R2 併發測試的場景資料（merge-review R1 M1，實測重現 40P01：
-- LS-155-driver.out／LS-155-e3-*.sql，reviewer 的三連線時序原樣搬進常駐迴歸）。
--
-- 家庭 X（family_id 較小）：UO（owner）＋U3（member）；U1**不是**X 的成員，但在 X
-- 留有一張 media（模擬已退出、留下照片——見 20260904070941_delete_account_media.sql
-- 檔頭「R2」段落）。家庭 A（family_id 較大）：UO＋U3＋U1 皆為成員，U1 在 A 也有
-- 一張自己的 media。U3 已標記 deletion_requested_at（finalize_account_deletion()
-- 的呼叫前提）。
--
-- 時序（見 s0／s1／s2）：S0 先鎖住 A 的 UO 成員列、持有 9 秒撐開視窗；S2
-- （finalize_account_deletion(U3)）2 秒後開始，依 family_id 遞增序先處理 X（無
-- 阻塞）、再嘗試鎖 A 的 family_members（被 S0 卡住）；S1（U1 的
-- delete_my_account()）5 秒後開始——R1 版本會在這裡與 S2 互鎖（40P01，reviewer
-- 已實測）；R2 修法後兩者的第一步都是搶 family_members(X)，不會死鎖，只是排隊，
-- 見 verify 的完整說明。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id in (
  'e8000000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000002'
);
delete from auth.users where id in (
  'e8000000-0000-4000-8000-000000000011',
  'e8000000-0000-4000-8000-000000000012',
  'e8000000-0000-4000-8000-000000000013'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('e8000000-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls155-cc-uo@ls155.test', now(), now(), '{}', '{}'),
  ('e8000000-0000-4000-8000-000000000012', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls155-cc-u3@ls155.test', now(), now(), '{}', '{}'),
  ('e8000000-0000-4000-8000-000000000013', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls155-cc-u1@ls155.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('e8000000-0000-4000-8000-000000000011', 'LS155 CC UO'),
  ('e8000000-0000-4000-8000-000000000012', 'LS155 CC U3'),
  ('e8000000-0000-4000-8000-000000000013', 'LS155 CC U1')
on conflict (id) do update set display_name = excluded.display_name, deletion_requested_at = null;

-- created_by 由 add_creator_as_owner trigger 寫成 UO
insert into public.families (id, name, created_by) values
  ('e8000000-0000-4000-8000-000000000001', 'LS155 CC 家 X（U1 已退出，留有 media）', 'e8000000-0000-4000-8000-000000000011'),
  ('e8000000-0000-4000-8000-000000000002', 'LS155 CC 家 A（U1 仍是成員）', 'e8000000-0000-4000-8000-000000000011');

insert into public.family_members (family_id, user_id, role, can_upload) values
  ('e8000000-0000-4000-8000-000000000001', 'e8000000-0000-4000-8000-000000000012', 'member', true),
  ('e8000000-0000-4000-8000-000000000002', 'e8000000-0000-4000-8000-000000000012', 'member', true),
  ('e8000000-0000-4000-8000-000000000002', 'e8000000-0000-4000-8000-000000000013', 'member', true);

insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('e8000000-0000-4000-8000-000000000021', 'e8000000-0000-4000-8000-000000000001',
   'e8000000-0000-4000-8000-000000000001/2026/08/e8000000-0000-4000-8000-000000000021.jpg',
   'photo', 500000, now(), 10, 10, 'e8000000-0000-4000-8000-000000000013'),
  ('e8000000-0000-4000-8000-000000000022', 'e8000000-0000-4000-8000-000000000002',
   'e8000000-0000-4000-8000-000000000002/2026/08/e8000000-0000-4000-8000-000000000022.jpg',
   'photo', 300000, now(), 10, 10, 'e8000000-0000-4000-8000-000000000013');

-- U3 已呼叫過 delete_my_account()（finalize_account_deletion 的呼叫前提）。
update public.profiles set deletion_requested_at = now() where id = 'e8000000-0000-4000-8000-000000000012';

do $$
declare
  v_members_x int;
  v_members_a int;
begin
  select count(*) into v_members_x from public.family_members where family_id = 'e8000000-0000-4000-8000-000000000001';
  select count(*) into v_members_a from public.family_members where family_id = 'e8000000-0000-4000-8000-000000000002';
  if v_members_x <> 2 then
    raise exception 'SETUP FAIL：家 X 應有 2 位成員（UO／U3），實際 %', v_members_x;
  end if;
  if v_members_a <> 3 then
    raise exception 'SETUP FAIL：家 A 應有 3 位成員（UO／U3／U1），實際 %', v_members_a;
  end if;
  raise notice 'ok setup：家 X（U1 已退出留有 media）／家 A（U1 仍是成員）就緒，U3 已標記 deletion_requested_at';
end;
$$;
