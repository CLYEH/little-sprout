-- 併發場景一的最終狀態斷言：不論誰快誰慢，一支 max_uses = 1 的邀請碼
-- 都只能產生一筆申請，used_count 也只能是 1。
--
-- 這是整組併發測試真正要保護的東西：邀請碼的次數上限是隱私要求（PLAN §5、§8），
-- 超賣一次就是多一個陌生人有機會進到家庭裡。

\set ON_ERROR_STOP on

do $$
declare
  v_reqs int;
  v_used int;
  v_max int;
  v_members int;
begin
  select count(*) into v_reqs from public.join_requests
   where family_id = 'fe000000-0000-4000-8000-000000000001';
  select i.used_count, i.max_uses into v_used, v_max
    from public.invites i where i.code = 'RACE2345';
  select count(*) into v_members from public.family_members
   where family_id = 'fe000000-0000-4000-8000-000000000001';

  if v_reqs <> 1 then
    raise exception
      'FAIL 併發：max_uses=1 的邀請碼產生了 % 筆申請（名額被超賣）', v_reqs;
  end if;
  if v_used <> 1 or v_used > v_max then
    raise exception
      'FAIL 併發：used_count = %（max_uses = %）', v_used, v_max;
  end if;
  -- 家庭開著審核，所以此時只該有 owner 一位成員，申請人都還沒進來
  if v_members <> 1 then
    raise exception
      'FAIL 併發：家庭成員數 %（期望只有 owner 1 位——待審核的申請人不該已經在家庭裡）', v_members;
  end if;

  raise notice 'ok 併發：最終狀態 1 筆申請 / used_count %/%／成員 % 位', v_used, v_max, v_members;
end;
$$;
