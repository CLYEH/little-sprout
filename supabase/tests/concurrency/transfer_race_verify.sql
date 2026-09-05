-- LS-206 merge-review R1 m1 併發場景的最終狀態斷言。
--
-- S1（O→A）先開始、持鎖 3 秒才 commit；S2（O→B）1.2 秒後才動，必然被 S1 擋住、
-- 解除阻塞後必然發現 O 已經不是 owner 而被 LS058 擋下（見 transfer_race_s2.sql
-- 的說明）。終態必須是：家庭仍只有 1 位 owner（A），O 與 B 皆為 member——不是
-- 「A、B 都被扶正成 owner」（那是拿掉 FOR UPDATE 的 mutant才會出現的錯誤終態）。

\set ON_ERROR_STOP on

do $$
declare
  v_owners int;
  v_role_o public.family_role;
  v_role_a public.family_role;
  v_role_b public.family_role;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'de000000-0000-4000-8000-000000000001' and role = 'owner';

  select role into v_role_o from public.family_members
   where family_id = 'de000000-0000-4000-8000-000000000001'
     and user_id = 'de100000-0000-4000-8000-000000000001';
  select role into v_role_a from public.family_members
   where family_id = 'de000000-0000-4000-8000-000000000001'
     and user_id = 'de100000-0000-4000-8000-000000000002';
  select role into v_role_b from public.family_members
   where family_id = 'de000000-0000-4000-8000-000000000001'
     and user_id = 'de100000-0000-4000-8000-000000000003';

  if v_owners <> 1 then
    raise exception
      'FAIL 併發：家庭應恰好剩 1 位 owner，實際 % 位——兩句 FOR UPDATE 沒有守住併發轉移的序列化（見 migration 檔頭第 2 節）',
      v_owners;
  end if;

  if v_role_o <> 'member' or v_role_a <> 'owner' or v_role_b <> 'member' then
    raise exception
      'FAIL 併發：終態角色不對，O=%（應 member）A=%（應 owner）B=%（應 member，S2 的轉移應被 LS058 擋下、不生效）',
      v_role_o, v_role_a, v_role_b;
  end if;

  raise notice 'ok 併發：最終狀態 owner 1 位（A），O／B 皆為 member（S1 的轉移生效、S2 正確被 LS058 擋下）';
end;
$$;
