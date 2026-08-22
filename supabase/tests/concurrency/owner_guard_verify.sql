-- 併發場景的最終狀態斷言：不論兩個 session 誰贏，家庭都必須還有 owner。
--
-- 這是整組併發測試真正要保護的東西——「0 owner 的家庭」沒有任何自救路徑：
-- 所有管理 policy（加人、改角色、刪內容、處理檢舉）都要求 owner。

\set ON_ERROR_STOP on

do $$
declare
  v_owners int;
  v_members int;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'fd000000-0000-4000-8000-000000000001' and role = 'owner';
  select count(*) into v_members from public.family_members
   where family_id = 'fd000000-0000-4000-8000-000000000001';

  if v_owners < 1 then
    raise exception
      'FAIL 併發：併發結束後家庭剩 % 位 owner（成員共 % 位）—— 家庭已磚化', v_owners, v_members;
  end if;
  raise notice 'ok 併發：最終狀態 owner % 位 / 成員 % 位（≥1 owner 成立）', v_owners, v_members;
end;
$$;
