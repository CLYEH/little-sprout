-- LS-6 驗收條件 (b)：每個 family 恆有 ≥1 位 owner
-- PLAN §5「這條約束是帳號刪除流程能成立的基礎」、§9-A2。
--
-- 這個不變量若失效，後果不是資料髒掉而是「整個家庭與所有人的照片懸空」：
-- 沒有 owner 就沒有人能邀請、移除成員或刪內容，而 App Store 又規定帳號必須能在 app 內刪除。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. 刪掉最後一位 owner（家庭還有其他成員）→ 必須噴錯
--    LS-206：新增的 BEFORE DELETE ROW-level trigger（family_members_ownership_
--    transfer_guard）比既有的 AFTER STATEMENT trigger（enforce_family_has_owner）
--    先觸發，這個情境（role=owner、無其他 owner、但仍有其他成員）現在改回更明確
--    的 LS057，不再落到本來籠統的 LS001（LS001 仍在，但這個情境已經先被 LS057
--    攔下，不會被 LS001 看到——見 108_family_ownership_guard.sql 對兩者分工的
--    完整測試）。
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    delete from public.family_members
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：刪掉最後一位 owner 竟然成功了';
  exception when sqlstate 'LS057' then
    raise notice 'ok：刪除最後一位 owner 被擋下（LS-206 新碼）→ %', sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. 把最後一位 owner 降級 → 必須噴錯
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    update public.family_members set role = 'member'
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：把最後一位 owner 降級竟然成功了';
  exception when sqlstate 'LS001' then
    raise notice 'ok：降級最後一位 owner 被擋下 → %', sqlerrm;
  end;

  begin
    update public.family_members set role = 'viewer'
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：把最後一位 owner 降成 viewer 竟然成功了';
  exception when sqlstate 'LS001' then
    raise notice 'ok：降級成 viewer 一樣被擋下';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. 一句 UPDATE 同時「升 B 為 owner、降 A 為 member」必須成功
--    （這是 statement-level trigger 存在的理由：row-level 會在處理到 A 那列時誤判成沒有 owner，
--      而這正是 §9-A2 帳號刪除前「轉移 owner」的自然寫法）
-- ---------------------------------------------------------------------------
do $$
declare
  v_owners int;
begin
  update public.family_members
     set role = case when user_id = 'a0000000-0000-4000-8000-000000000001'
                     then 'member'::public.family_role
                     else 'owner'::public.family_role end
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id in ('a0000000-0000-4000-8000-000000000001',
                     'a0000000-0000-4000-8000-000000000002');

  select count(*) into v_owners from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001' and role = 'owner';
  if v_owners <> 1 then
    raise exception 'FAIL：交接後 owner 數應為 1，實際 %', v_owners;
  end if;
  raise notice 'ok：同一句 UPDATE 完成 owner 交接（statement-level 檢查）';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. 先指派新 owner、再刪掉舊 owner → 必須成功（§9-A2 的帳號刪除路徑）
-- ---------------------------------------------------------------------------
do $$
declare
  v_owners int;
begin
  update public.family_members set role = 'owner'
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'a0000000-0000-4000-8000-000000000001';

  delete from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'a0000000-0000-4000-8000-000000000002';

  select count(*) into v_owners from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001' and role = 'owner';
  if v_owners <> 1 then
    raise exception 'FAIL：交接後應剩 1 位 owner，實際 %', v_owners;
  end if;
  raise notice 'ok：先指派新 owner 再移除舊 owner 可以成功（多 owner 並存也可以）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 5. 刪掉整個家庭不該被不變量擋住（cascade 掉全部成員是合法的）
-- ---------------------------------------------------------------------------
begin;
do $$
declare
  v_n int;
begin
  delete from public.families where id = 'fa000000-0000-4000-8000-000000000001';
  select count(*) into v_n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL：家庭刪掉了但成員列還在 % 列', v_n;
  end if;
  raise notice 'ok：刪除整個家庭不會被 owner 不變量誤擋';
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 6. 走 app 的實際路徑（authenticated + RLS）也一樣擋得住：
--    最後一位 owner 想自己退出家庭（家庭還有其他成員，LS-206：LS057）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  begin
    delete from public.family_members
     where family_id = 'fa000000-0000-4000-8000-000000000001'
       and user_id = 'a0000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：最後一位 owner 透過 app 路徑退出家庭竟然成功了';
  exception when sqlstate 'LS057' then
    raise notice 'ok：authenticated 路徑下，最後一位 owner 也退不掉（LS-206 新碼）→ %', sqlerrm;
  end;
end;
$$;
rollback;

-- ---------------------------------------------------------------------------
-- 7. 一般成員退出自己所在的家庭要能成功（否則長輩被誤加進來就出不去）
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_n int;
begin
  delete from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'a0000000-0000-4000-8000-000000000003';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：viewer 退不出自己所在的家庭（影響 % 列）', v_n;
  end if;
  raise notice 'ok：非 owner 成員可以自行退出家庭';
end;
$$;
rollback;
