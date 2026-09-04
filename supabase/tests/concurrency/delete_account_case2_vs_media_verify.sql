-- LS-155 R3 併發場景「情況 2 vs media（N2）」的最終狀態斷言。
--
-- race_case3（本場景沿用同一支三連線 runner）已經檢查過 S0／S1／S2 三個 session
-- 皆以 rc=0 結束（沒有收到 40P01）——這是本測試最重要的斷言，直接證明 R3 修法後
-- reviewer N2 的三連線時序不會死鎖。這裡再核對最終資料狀態正確：U1 的兩個唯一
-- 成員家庭（S、S2）都被 cascade 刪除（連帶清掉 U2 早已退出留下的 media、U1 自己
-- 在飛上傳的那張），兩支硬刪都正確入列 Storage 清除佇列，U1／U2 的
-- profiles.deletion_requested_at 皆已標記。

\set ON_ERROR_STOP on

do $$
declare
  v_n int;
  v_u1_requested timestamptz;
  v_u2_requested timestamptz;
  v_path_u2 text := 'ed000000-0000-4000-8000-000000000001/2026/08/ed000000-0000-4000-8000-000000000021.jpg';
  v_path_upload text := 'ed000000-0000-4000-8000-000000000002/2026/08/ed000000-0000-4000-8000-000000000022.jpg';
begin
  select count(*) into v_n from public.families
   where id in ('ed000000-0000-4000-8000-000000000001', 'ed000000-0000-4000-8000-000000000002');
  if v_n <> 0 then
    raise exception 'FAIL 併發：U1 的兩個唯一成員家庭應該都已 cascade 刪除，實際還剩 % 個', v_n;
  end if;

  select count(*) into v_n from public.media
   where id in ('ed000000-0000-4000-8000-000000000021', 'ed000000-0000-4000-8000-000000000022');
  if v_n <> 0 then
    raise exception 'FAIL 併發：U2 早已退出留下的 media 與 U1 在飛上傳的 media 應該都隨家庭 cascade 硬刪，實際還剩 % 列', v_n;
  end if;

  select count(*) into v_n from public.purge_storage_queue where object_path in (v_path_u2, v_path_upload);
  if v_n <> 2 then
    raise exception 'FAIL 併發：兩張 media 的 storage_path 應該都已入列 purge_storage_queue，實際 % 筆', v_n;
  end if;

  select deletion_requested_at into v_u1_requested from public.profiles where id = 'ed000000-0000-4000-8000-000000000011';
  if v_u1_requested is null then
    raise exception 'FAIL 併發：U1 的 profiles.deletion_requested_at 沒有被標記';
  end if;

  select deletion_requested_at into v_u2_requested from public.profiles where id = 'ed000000-0000-4000-8000-000000000012';
  if v_u2_requested is null then
    raise exception 'FAIL 併發：U2 的 profiles.deletion_requested_at 沒有被標記';
  end if;

  raise notice 'ok 併發：三連線時序（S0 真實在飛上傳撐開視窗、S1 U1 情況2 cascade、S2 U2 情況3 media-only）皆正常完成無死鎖；U1 的兩個唯一成員家庭與其中的 media 全部正確 cascade 硬刪並入列 Storage 清除，U1／U2 皆正確標記 deletion_requested_at';
end;
$$;
