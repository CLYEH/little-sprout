-- LS-206 — family_members BEFORE DELETE 守門（LS057）＋ transfer_ownership() RPC
-- （LS058／LS059／LS060）。設計推演（包含「刻意不做的事」的完整理由）見對應
-- migration 檔頭：supabase/migrations/20260905132350_family_ownership_guard.sql。
--
-- 一般成員家庭（唯一 owner、有其他成員）沿用 00_fixtures.sql 的 A 家
-- （fa000000-...-0001：owner a1、member a2、viewer a3）。本檔另建三個專屬
-- fixture 家庭（eb 前綴——00_fixtures.sql 與既有測試檔皆未用過這個前綴）：
--   F1 = eb000000-...-0001：兩位 owner（u1、u2），無其他成員
--   F2 = eb000000-...-0002：唯一 owner 兼唯一成員（u3）
--   F3 = eb000000-...-0003：transfer_ownership 測試家，owner u4 ＋ member u5 ＋
--        member u6；u7 不屬於這個家庭，用來測「對方非成員」。

\set ON_ERROR_STOP on

delete from public.families where id in (
  'eb000000-0000-4000-8000-000000000001',
  'eb000000-0000-4000-8000-000000000002',
  'eb000000-0000-4000-8000-000000000003'
);
delete from auth.users where id in (
  'eb100000-0000-4000-8000-000000000001',
  'eb100000-0000-4000-8000-000000000002',
  'eb100000-0000-4000-8000-000000000003',
  'eb100000-0000-4000-8000-000000000004',
  'eb100000-0000-4000-8000-000000000005',
  'eb100000-0000-4000-8000-000000000006',
  'eb100000-0000-4000-8000-000000000007'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('eb100000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u1@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u2@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u3@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u4@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u5@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000006', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u6@ls206.test', now(), now(), '{}', '{}'),
  ('eb100000-0000-4000-8000-000000000007', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls206-u7@ls206.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('eb100000-0000-4000-8000-000000000001', 'LS206 U1'),
  ('eb100000-0000-4000-8000-000000000002', 'LS206 U2'),
  ('eb100000-0000-4000-8000-000000000003', 'LS206 U3'),
  ('eb100000-0000-4000-8000-000000000004', 'LS206 U4'),
  ('eb100000-0000-4000-8000-000000000005', 'LS206 U5'),
  ('eb100000-0000-4000-8000-000000000006', 'LS206 U6'),
  ('eb100000-0000-4000-8000-000000000007', 'LS206 U7')
on conflict (id) do update set display_name = excluded.display_name;

-- families 的 AFTER INSERT trigger（add_creator_as_owner）自動把 created_by 寫成 owner。
insert into public.families (id, name, created_by) values
  ('eb000000-0000-4000-8000-000000000001', 'LS206 F1 雙 Owner 家', 'eb100000-0000-4000-8000-000000000001'),
  ('eb000000-0000-4000-8000-000000000002', 'LS206 F2 獨居家', 'eb100000-0000-4000-8000-000000000003'),
  ('eb000000-0000-4000-8000-000000000003', 'LS206 F3 轉移測試家', 'eb100000-0000-4000-8000-000000000004');

insert into public.family_members (family_id, user_id, role) values
  ('eb000000-0000-4000-8000-000000000001', 'eb100000-0000-4000-8000-000000000002', 'owner'),
  ('eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000005', 'member'),
  ('eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000006', 'member');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.family_members where family_id = 'eb000000-0000-4000-8000-000000000001';
  if v_n <> 2 then raise exception 'FIXTURE FAIL：F1 應有 2 位成員，實際 %', v_n; end if;
  select count(*) into v_n from public.family_members where family_id = 'eb000000-0000-4000-8000-000000000002';
  if v_n <> 1 then raise exception 'FIXTURE FAIL：F2 應有 1 位成員，實際 %', v_n; end if;
  select count(*) into v_n from public.family_members where family_id = 'eb000000-0000-4000-8000-000000000003';
  if v_n <> 3 then raise exception 'FIXTURE FAIL：F3 應有 3 位成員，實際 %', v_n; end if;
  raise notice 'ok fixtures：LS206 F1/F2/F3 建立完成';
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. 唯一 owner、家庭仍有其他成員退出 → LS057（DETAIL 帶 family_id/family_name）
-- ---------------------------------------------------------------------------
begin;
do $$
declare
  v_detail text;
begin
  begin
    delete from public.family_members
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：唯一 owner 在家庭仍有其他成員時退出竟然成功';
  exception when sqlstate 'LS057' then
    get stacked diagnostics v_detail = pg_exception_detail;
    if (v_detail::jsonb ->> 'family_id') <> 'fa000000-0000-4000-8000-000000000001' then
      raise exception 'FAIL：LS057 DETAIL 缺 family_id，實際 %', v_detail;
    end if;
    if (v_detail::jsonb ->> 'family_name') <> 'A 家' then
      raise exception 'FAIL：LS057 DETAIL 缺 family_name，實際 %', v_detail;
    end if;
    raise notice 'ok 情境1：唯一 owner、家庭仍有其他成員退出 → LS057，DETAIL=%', v_detail;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 2. owner 移除一般成員（非 owner）→ 允許（走 app 實際路徑，authenticated + RLS）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_n int;
begin
  delete from public.family_members
   where family_id = 'eb000000-0000-4000-8000-000000000003'
     and user_id = 'eb100000-0000-4000-8000-000000000006';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 移除一般成員應成功，影響 % 列', v_n;
  end if;
  raise notice 'ok 情境2：owner 移除一般成員成功（不涉及 owner 不變量）';
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 3. 有兩個 owner，其一退出 → 允許（F1：u1、u2 皆 owner，無其他成員）
-- ---------------------------------------------------------------------------
begin;
do $$
declare
  v_n int;
  v_owners int;
begin
  delete from public.family_members
   where family_id = 'eb000000-0000-4000-8000-000000000001'
     and user_id = 'eb100000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：雙 owner 家庭，其一退出應成功，影響 % 列', v_n;
  end if;
  select count(*) into v_owners from public.family_members
   where family_id = 'eb000000-0000-4000-8000-000000000001' and role = 'owner';
  if v_owners <> 1 then
    raise exception 'FAIL：退出後應剩 1 位 owner，實際 %', v_owners;
  end if;
  raise notice 'ok 情境3：雙 owner 家庭，其一退出成功、不需要先轉移';
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 4. 唯一 owner 且唯一成員退出（F2：u3）——deviation，見 migration 檔頭「刻意
--    不做的事」完整推演：這裡重複結論，不是票文驗收清單字面的「允許」，而是
--    仍被既有 LS001（AFTER STATEMENT trigger）擋下。原因：這個資料庫狀態轉換
--    （對 family_members 一句 DELETE，讓某個仍然存在的 families 列底下的
--    family_members 掛零）與 supabase/tests/concurrency/delete_account_race_
--    *.sql（LS-143，三輪 merge-review 才收斂的併發安全網：兩位共同 owner
--    幾乎同時呼叫 delete_my_account()，後動者的 DELETE 意外把家庭清到 0 位
--    成員時必須被 LS001 擋下強迫重試，重試才會正確走「唯一成員→整個家庭
--    cascade 刪除」那條路，否則會留下一個 families 列還在、但沒有任何
--    family_members、也不會再被任何既有路徑枚舉到的孤兒列）是同一個資料庫
--    狀態轉換，在 trigger 層級無法用呼叫者身份區分。本票判斷是保留三輪加固
--    過的既有併發安全網，不修改 private.enforce_family_has_owner() 去放寬
--    這個情境。要真正離開唯一成員的獨居家，正確且本來就一直可行的路徑是
--    delete_my_account()（見 91_delete_account.sql 情境 3／105_
--    suspension_and_registrations.sql 場景 14，皆不受本票影響）。
-- ---------------------------------------------------------------------------
begin;
do $$
begin
  begin
    delete from public.family_members
     where family_id = 'eb000000-0000-4000-8000-000000000002'
       and user_id = 'eb100000-0000-4000-8000-000000000003';
    raise exception 'FAIL：唯一 owner 兼唯一成員直接自行退出竟然成功（見上方註解，預期仍被既有 LS001 擋下）';
  exception when sqlstate 'LS001' then
    raise notice 'ok 情境4（deviation，見上方與 migration 檔頭說明）：唯一 owner 兼唯一成員直接對 family_members 自行退出，仍被既有 LS001 擋下 → %；離開獨居家的正確路徑是 delete_my_account()', sqlerrm;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 5. transfer_ownership 正常轉移（F3：owner u4 → member u5）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_from_user uuid;
  v_from_role public.family_role;
  v_to_user uuid;
  v_to_role public.family_role;
begin
  select from_user_id, from_role, to_user_id, to_role
    into v_from_user, v_from_role, v_to_user, v_to_role
    from public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000005');

  if v_from_user <> 'eb100000-0000-4000-8000-000000000004' or v_from_role <> 'member' then
    raise exception 'FAIL：回傳的原 owner 新角色不對，from_user=% from_role=%', v_from_user, v_from_role;
  end if;
  if v_to_user <> 'eb100000-0000-4000-8000-000000000005' or v_to_role <> 'owner' then
    raise exception 'FAIL：回傳的新 owner 角色不對，to_user=% to_role=%', v_to_user, v_to_role;
  end if;
  raise notice 'ok 情境5：transfer_ownership 回傳角色對正確（原 owner→member，對方→owner）';
end;
$$;
reset role;

do $$
declare
  v_role public.family_role;
begin
  select role into v_role from public.family_members
   where family_id = 'eb000000-0000-4000-8000-000000000003'
     and user_id = 'eb100000-0000-4000-8000-000000000004';
  if v_role <> 'member' then raise exception 'FAIL：原 owner u4 資料庫實際角色應為 member，實際 %', v_role; end if;

  select role into v_role from public.family_members
   where family_id = 'eb000000-0000-4000-8000-000000000003'
     and user_id = 'eb100000-0000-4000-8000-000000000005';
  if v_role <> 'owner' then raise exception 'FAIL：u5 資料庫實際角色應為 owner，實際 %', v_role; end if;

  raise notice 'ok 情境5 續：資料庫實際狀態正確（u4→member，u5→owner）';
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 6. transfer_ownership 非 owner 呼叫 → LS058（u5 是 member，不是 owner）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000005","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000006');
    raise exception 'FAIL：非 owner 呼叫 transfer_ownership 竟然成功';
  exception when sqlstate 'LS058' then
    raise notice 'ok 情境6：非 owner 呼叫 transfer_ownership → LS058 → %', sqlerrm;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 7. transfer_ownership 對方非現任成員 → LS059（u7 不屬於 F3）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000007');
    raise exception 'FAIL：轉移給非該家庭成員竟然成功';
  exception when sqlstate 'LS059' then
    raise notice 'ok 情境7：對方不是該家庭目前的成員 → LS059 → %', sqlerrm;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 8. transfer_ownership 對方＝自己 → LS060
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000004');
    raise exception 'FAIL：轉移給自己竟然成功';
  exception when sqlstate 'LS060' then
    raise notice 'ok 情境8：對方＝呼叫者自己 → LS060 → %', sqlerrm;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 9. 未登入呼叫 transfer_ownership → 42501
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
begin
  begin
    perform public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000005');
    raise exception 'FAIL：anon 呼叫 transfer_ownership 竟然成功';
  exception when insufficient_privilege then
    raise notice 'ok 情境9：anon 呼叫 transfer_ownership 被 grant 擋下（42501）';
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 10. 兩筆併發轉移的序列化等價證明（票文明文允許：「第二筆在第一筆 commit 後
--     執行 → 呼叫者已非 owner → LS0xx」）：owner u4 對兩個不同對象各發一次
--     transfer_ownership。migration 檔頭第 2 節的鎖序（兩句各自的 for update，
--     依 user_id 遞增序）讓兩筆真正併發的呼叫依序排隊、互斥執行，效果等同這裡
--     「第一筆先 commit、第二筆之後才執行」——後排的那筆解鎖後用全新查詢重新
--     讀到呼叫者已經是 member，正確噴出 LS058，不會讓兩個人都被錯誤地扶正成
--     owner。這是本檔最後一個情境，刻意不 rollback（F3 的狀態變更沒有下一個
--     情境依賴它）。
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.transfer_ownership(
    'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000005');
end;
$$;
reset role;
commit;

begin;
select set_config('request.jwt.claims',
  '{"sub":"eb100000-0000-4000-8000-000000000004","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.transfer_ownership(
      'eb000000-0000-4000-8000-000000000003', 'eb100000-0000-4000-8000-000000000006');
    raise exception 'FAIL：第一筆轉移已 commit、呼叫者已非 owner，第二筆竟然成功';
  exception when sqlstate 'LS058' then
    raise notice 'ok 情境10：序列化後，呼叫者已非 owner 的第二筆轉移 → LS058 → %（等價於兩筆真正併發時，FOR UPDATE 鎖序排隊後的後排結果）', sqlerrm;
  end;
end;
$$;
reset role;
rollback;
