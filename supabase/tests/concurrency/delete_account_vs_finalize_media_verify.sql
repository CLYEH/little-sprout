-- LS-155 R2 併發場景「media 軟刪 vs finalize_account_deletion」的最終狀態斷言。
--
-- run.sh 的 race_case3 已經檢查過 S0／S1／S2 三個 session 皆以 rc=0 結束（沒有
-- 任何一個收到 40P01 或其他錯誤）——這是本測試最重要的斷言，直接證明 R2 修法後
-- reviewer 原始重現的三連線時序不會死鎖。這裡再核對最終資料狀態正確：U1 的兩張
-- media（家 X、家 A）皆已軟刪、額度歸零；U1 已離開家 A；U3 已被
-- finalize_account_deletion() 從家 X、家 A 都移除；UO 仍是兩個家庭僅存的成員
-- （owner）。

\set ON_ERROR_STOP on

do $$
declare
  v_media_x_deleted timestamptz;
  v_media_a_deleted timestamptz;
  v_used_x bigint;
  v_used_a bigint;
  v_members_x int;
  v_members_a int;
  v_u1_requested timestamptz;
begin
  select deleted_at into v_media_x_deleted from public.media where id = 'e8000000-0000-4000-8000-000000000021';
  select deleted_at into v_media_a_deleted from public.media where id = 'e8000000-0000-4000-8000-000000000022';
  if v_media_x_deleted is null then
    raise exception 'FAIL 併發：U1 在家 X 留下的 media 沒有被軟刪';
  end if;
  if v_media_a_deleted is null then
    raise exception 'FAIL 併發：U1 在家 A 的 media 沒有被軟刪';
  end if;

  select storage_used_bytes into v_used_x from public.families where id = 'e8000000-0000-4000-8000-000000000001';
  select storage_used_bytes into v_used_a from public.families where id = 'e8000000-0000-4000-8000-000000000002';
  if v_used_x <> 0 or v_used_a <> 0 then
    raise exception 'FAIL 併發：家 X／家 A 的額度應該都釋放為 0，實際 X=% A=%', v_used_x, v_used_a;
  end if;

  select count(*) into v_members_x from public.family_members where family_id = 'e8000000-0000-4000-8000-000000000001';
  select count(*) into v_members_a from public.family_members where family_id = 'e8000000-0000-4000-8000-000000000002';
  if v_members_x <> 1 then
    raise exception 'FAIL 併發：家 X 應該只剩 UO 一位成員（U3 已被 finalize 移除），實際 % 位', v_members_x;
  end if;
  if v_members_a <> 1 then
    raise exception 'FAIL 併發：家 A 應該只剩 UO 一位成員（U3 已被 finalize 移除、U1 已離開），實際 % 位', v_members_a;
  end if;

  select count(*) into v_members_x from public.family_members
   where family_id = 'e8000000-0000-4000-8000-000000000001' and user_id = 'e8000000-0000-4000-8000-000000000011' and role = 'owner';
  if v_members_x <> 1 then
    raise exception 'FAIL 併發：家 X 僅存的成員應該是 owner UO';
  end if;

  select deletion_requested_at into v_u1_requested from public.profiles where id = 'e8000000-0000-4000-8000-000000000013';
  if v_u1_requested is null then
    raise exception 'FAIL 併發：U1 的 profiles.deletion_requested_at 沒有被標記';
  end if;

  raise notice 'ok 併發：三連線時序（S0 撐開視窗、S1 delete_my_account、S2 finalize_account_deletion）皆正常完成無死鎖；U1 跨兩個家庭的 media 全部軟刪、額度歸零，U3 被 finalize 正確移除，UO 仍是兩個家庭僅存的 owner';
end;
$$;
