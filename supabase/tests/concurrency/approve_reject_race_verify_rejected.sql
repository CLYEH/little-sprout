-- 併發場景二（方向 B：拒絕先動）的最終狀態斷言。
--
-- 這個方向的結果是確定的，不是「誰快誰慢」：媽媽的拒絕先取得列鎖並先 commit，
-- 爸爸的核准排在後面、重讀到 rejected 之後應該整個放棄。所以最終狀態必須是
--   status = 'rejected' 且申請人不在 family_members 裡
-- ——也就是驗收條件「拒絕後無殘留權限」在併發下仍然成立。
--
-- 只斷言「狀態與成員一致」是不夠的：核准若沒被擋下，最終會變成
-- status = 'approved' + 成員存在，那也是「一致」的，但媽媽的拒絕被無聲推翻了。
-- 所以這裡直接寫死「拒絕必須贏」。

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

  if v_status <> 'rejected' then
    raise exception
      'FAIL 併發：先 commit 的拒絕被推翻了（最終 status=%）—— 按下拒絕的 owner 沒有收到任何錯誤，卻沒擋下這個人',
      v_status;
  end if;
  if v_member then
    raise exception
      'FAIL 併發：申請被拒絕，申請人卻在 family_members 裡（殘留權限）—— 他看得到全家的照片';
  end if;

  raise notice 'ok 併發：拒絕先動時最終為 rejected 且申請人不在家庭裡';
end;
$$;
