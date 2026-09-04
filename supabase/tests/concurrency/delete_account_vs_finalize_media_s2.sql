-- LS-155 R2 併發場景「media 軟刪 vs finalize_account_deletion」的 session 2。
--
-- 2 秒後以 service_role 呼叫 finalize_account_deletion(U3)：依 family_id 遞增序
-- 先處理家 X（U3 是一般 member，直接刪除他那一列，無阻塞）、再處理家 A——嘗試鎖
-- family_members(A) 時撞上 S0 持有的 UO 成員列鎖，阻塞到 S0 在第 9 秒釋放。R1
-- 版本：S1（delete_my_account）此時可能已經鎖住 families(A)（透過 owner_guard）
-- 並持有它、正在等 families(X)（R1 版本 media UPDATE 觸發），而 S2 持有
-- family_members(X)、正在等 family_members(A)——兩邊互等，40P01（reviewer 實測，
-- 錯誤訊息見 setup 檔頭引用的 LS-155-driver.out）。R2 修法後預期正常完成。

\set ON_ERROR_STOP on

begin;

do $$
begin
  perform pg_sleep(2);

  set local role service_role;
  perform public.finalize_account_deletion('e8000000-0000-4000-8000-000000000012');
  reset role;
end;
$$;

commit;

\echo 'S2：finalize_account_deletion(U3) 已 commit'
