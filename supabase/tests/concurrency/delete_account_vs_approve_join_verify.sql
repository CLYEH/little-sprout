-- LS-143 R2（merge-review R1 m2）併發場景的最終狀態斷言。
--
-- 這是整組測試真正要保護的東西：m2 修好之前，這裡的家庭會被整個 cascade 刪除
-- （連同剛核准加入的 C）；修好之後，家庭必須存活，只有 A 離開，C 留下且是 owner。

\set ON_ERROR_STOP on

do $$
declare
  v_family_exists boolean;
  v_members int;
  v_c_role public.family_role;
  v_a_left boolean;
  v_a_requested timestamptz;
  v_status public.join_request_status;
begin
  select exists(select 1 from public.families where id = 'd5000000-0000-4000-8000-000000000001')
    into v_family_exists;
  if not v_family_exists then
    raise exception
      'FAIL 併發：LS143 vs-approve 測試家整個消失了——m2 沒有修好，剛核准加入的成員被連坐 cascade 刪除';
  end if;

  select count(*) into v_members from public.family_members
   where family_id = 'd5000000-0000-4000-8000-000000000001';
  if v_members <> 1 then
    raise exception 'FAIL 併發：家庭應恰好剩 1 位成員（C，A 已離開），實際 %', v_members;
  end if;

  select role into v_c_role from public.family_members
   where family_id = 'd5000000-0000-4000-8000-000000000001'
     and user_id = 'd7000000-0000-4000-8000-000000000001';
  if v_c_role is null then
    raise exception 'FAIL 併發：C 不在家庭裡——核准的結果被吃掉了';
  end if;
  if v_c_role <> 'owner' then
    raise exception 'FAIL 併發：C 的角色應該是 owner（邀請碼設定），實際 %', v_c_role;
  end if;

  select not exists(
    select 1 from public.family_members
     where family_id = 'd5000000-0000-4000-8000-000000000001'
       and user_id = 'd6000000-0000-4000-8000-000000000001'
  ) into v_a_left;
  if not v_a_left then
    raise exception 'FAIL 併發：A 的 delete_my_account() 已 commit，但他仍留在 family_members';
  end if;

  select deletion_requested_at into v_a_requested from public.profiles
   where id = 'd6000000-0000-4000-8000-000000000001';
  if v_a_requested is null then
    raise exception 'FAIL 併發：A 成功刪帳號（改走情況 3），但 profiles.deletion_requested_at 沒有標記';
  end if;

  select status into v_status from public.join_requests
   where id = 'd9000000-0000-4000-8000-000000000001';
  if v_status <> 'approved' then
    raise exception 'FAIL 併發：申請最終狀態應為 approved，實際 %', v_status;
  end if;

  raise notice 'ok 併發：家庭存活、C 是唯一成員且角色 owner、A 已離開並標記 deletion_requested_at——m2 修正生效（改走情況 3，不是連坐 cascade）';
end;
$$;
