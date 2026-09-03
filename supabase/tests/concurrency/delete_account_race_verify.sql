-- LS-143 併發場景的最終狀態斷言。
--
-- 跟 owner_guard_verify.sql 驗的是同一件事（家庭必須還有 owner，不能磚化），但
-- 這裡的終態是確定的（不是「不論誰贏」）：S1（owner 1）先開始、持鎖 3 秒才
-- commit，S2（owner 2）1.2 秒後才動，必然被 S1 擋住、且必然在解除阻塞後才發現
-- 自己已是最後一人而被 LS001 擋下（見 delete_account_race_s2.sql 的說明）。所以
-- 終態必須是：家庭還在、只剩 owner 2 一人（仍是 owner）、owner 1 已經離開，
-- owner 1 的 profiles.deletion_requested_at 已標記、owner 2 的沒有（它的呼叫被
-- 回滾了）。

\set ON_ERROR_STOP on

do $$
declare
  v_owners int;
  v_members int;
  v_owner1_left boolean;
  v_owner1_requested timestamptz;
  v_owner2_requested timestamptz;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'd3000000-0000-4000-8000-000000000001' and role = 'owner';
  select count(*) into v_members from public.family_members
   where family_id = 'd3000000-0000-4000-8000-000000000001';

  if v_owners < 1 then
    raise exception
      'FAIL 併發：併發結束後家庭剩 % 位 owner（成員共 % 位）—— 家庭已磚化', v_owners, v_members;
  end if;

  select not exists (
    select 1 from public.family_members
     where family_id = 'd3000000-0000-4000-8000-000000000001'
       and user_id = 'd4000000-0000-4000-8000-000000000001'
  ) into v_owner1_left;
  if not v_owner1_left then
    raise exception 'FAIL 併發：owner 1 的 delete_my_account() 已 commit，但他仍留在 family_members';
  end if;

  if v_members <> 1 then
    raise exception 'FAIL 併發：家庭應恰好剩 1 位成員（owner 2，owner 1 已離開、owner 2 的呼叫被 LS001 回滾），實際 %', v_members;
  end if;

  select deletion_requested_at into v_owner1_requested from public.profiles
   where id = 'd4000000-0000-4000-8000-000000000001';
  if v_owner1_requested is null then
    raise exception 'FAIL 併發：owner 1 成功刪帳號，但 profiles.deletion_requested_at 沒有標記';
  end if;

  select deletion_requested_at into v_owner2_requested from public.profiles
   where id = 'd4000000-0000-4000-8000-000000000002';
  if v_owner2_requested is not null then
    raise exception 'FAIL 併發：owner 2 的 delete_my_account() 應該被 LS001 回滾，deletion_requested_at 不該被標記';
  end if;

  raise notice 'ok 併發：最終狀態 owner % 位 / 成員 % 位（≥1 owner 成立，owner 1 已離開、owner 2 因 LS001 回滾仍在）', v_owners, v_members;
end;
$$;
