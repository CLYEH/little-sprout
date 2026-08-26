-- LS-110 R1 F2 — 驗證＋清理 profiles_trigger_probe_insert.sql 的結果。
--
-- 用一般連線（postgres／db_user，profiles 的 owner）跑，不是 supabase_auth_admin：
-- 後者對 public.profiles 沒有任何 grant（正式路徑上 GoTrue 本來就不需要讀這張
-- 表），直接拿它讀會得到「permission denied for table profiles」，跟這裡要驗的
-- 東西（trigger 在 supabase_auth_admin 身分下有沒有正確建立 profiles 列）無關。

\set ON_ERROR_STOP on

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-0000000000aa';
  if v_name is null then
    raise exception 'FAIL：以 supabase_auth_admin 身分 insert auth.users 後 profiles 沒有自動建立';
  end if;
  if v_name <> '正式路徑角色測試' then
    raise exception 'FAIL：display_name 推導錯誤（實際「%」）', v_name;
  end if;
  raise notice 'ok：supabase_auth_admin 角色路徑下 trigger 正常運作（display_name=%）', v_name;
end;
$$;

-- 清理：public.profiles 的 FK 對 auth.users 是 on delete cascade，刪這一列就夠了。
delete from auth.users where id = 'f1000000-0000-4000-8000-0000000000aa';
