-- 併發場景二的最終狀態斷言：申請的狀態與成員資格必須一致。
--
-- 「一致」的定義只有一條，但它同時涵蓋兩種輸法：
--   status = 'approved' ⇔ 申請人在 family_members 裡
-- 左邊成立右邊不成立 → 核准了卻沒進家（使用者被告知通過卻什麼都看不到）；
-- 右邊成立左邊不成立 → 這就是「拒絕後仍有殘留權限」，被拒絕的人看得到全家的照片。

\set ON_ERROR_STOP on

do $$
declare
  v_status public.join_request_status;
  v_member boolean;
begin
  select r.status into v_status from public.join_requests r
   where r.id = '9f000000-0000-4000-8000-000000000001';
  select exists (
    select 1 from public.family_members m
     where m.family_id = 'ff000000-0000-4000-8000-000000000001'
       and m.user_id = 'eb000000-0000-4000-8000-000000000003'
  ) into v_member;

  if (v_status = 'approved') is distinct from v_member then
    raise exception
      'FAIL 併發：申請狀態與成員資格不一致（status=%，在成員名單裡=%）—— %',
      v_status, v_member,
      case when v_member then '被拒絕的人還留在家庭裡（殘留權限）'
           else '核准了卻沒有寫入成員' end;
  end if;

  if v_status = 'pending' then
    raise exception 'FAIL 併發：兩個審核動作都沒有生效，申請還是 pending';
  end if;

  raise notice 'ok 併發：最終狀態一致（status=%，在成員名單裡=%）', v_status, v_member;
end;
$$;
