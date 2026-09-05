-- LS-197（LS-23 後端切片）— EULA 同意紀錄
--
-- 對應 migration 20260905051320_eula_consent.sql。沿用 00_fixtures.sql 的固定
-- 家庭／使用者（A 家：owner a1／member a2／viewer a3）。每個場景各自
-- begin/rollback，互不污染 fixtures（比照本目錄既有慣例）；場景內先把
-- app_settings.eula_version 改成一個測試專用的固定字串，不依賴 migration
-- 預設值的實際內容，跟版本字串本身的變動解耦。

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 場景 1：版本相符 → accept_eula() 成功寫入，且驗證 eula_version 的欄位級
-- SELECT 設計（client 讀得到這一欄，讀不到同表其他欄位）。
-- ---------------------------------------------------------------------------
begin;

update public.app_settings set eula_version = 'v-test-1', updated_at = now() where id = true;

do $$
declare
  v_read_version text;
  v_accepted_version text;
  v_accepted_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- client 讀得到 eula_version（欄位級 grant＋app_settings_select policy）。
  -- 刻意不帶 `where id = true`——本表只有一列，且欄位級權限連 WHERE 子句引用
  -- 到的欄位都會檢查，帶上 `id` 會因為 `id` 沒有 SELECT 權限而整句 42501
  -- （migration 檔頭第 2 點的既有教訓）。
  select eula_version into v_read_version from public.app_settings;
  if v_read_version <> 'v-test-1' then
    raise exception 'FAIL：authenticated 讀 app_settings.eula_version 應得到 v-test-1，實際 %', v_read_version;
  end if;

  -- 但讀不到同表其他欄位（沒有欄位級 grant，維持原本的封閉）
  begin
    perform registrations_open from public.app_settings;
    raise exception 'FAIL：authenticated 竟然讀得到 app_settings.registrations_open';
  exception when insufficient_privilege then
    null; -- ok
  end;

  perform public.accept_eula('v-test-1');

  select eula_accepted_version, eula_accepted_at into v_accepted_version, v_accepted_at
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000001';

  if v_accepted_version <> 'v-test-1' then
    raise exception 'FAIL：accept_eula 成功後 eula_accepted_version 應為 v-test-1，實際 %', v_accepted_version;
  end if;
  if v_accepted_at is null then
    raise exception 'FAIL：accept_eula 成功後 eula_accepted_at 仍是 NULL';
  end if;

  reset role;
  raise notice 'ok：版本相符時 accept_eula() 成功寫入兩欄，且 eula_version 欄位級 SELECT 設計符合預期（讀得到自己、讀不到 registrations_open）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 2：版本不符 → LS055，profiles 兩欄不受影響
-- ---------------------------------------------------------------------------
begin;

update public.app_settings set eula_version = 'v-test-1', updated_at = now() where id = true;

do $$
declare
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.accept_eula('v-stale-0');
    raise exception 'FAIL：p_version 與目前 eula_version 不相符，accept_eula() 竟然成功';
  exception when sqlstate 'LS055' then
    null; -- ok
  end;

  select count(*) into n from public.profiles
   where id = 'a0000000-0000-4000-8000-000000000001'
     and eula_accepted_version is not null;
  if n <> 0 then
    raise exception 'FAIL：版本不符時仍寫入了 eula_accepted_version';
  end if;

  reset role;
  raise notice 'ok：版本不符時 accept_eula() 回 LS055，profiles 兩欄未被寫入';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 3：未登入呼叫 → 42501
-- ---------------------------------------------------------------------------
begin;

update public.app_settings set eula_version = 'v-test-1', updated_at = now() where id = true;

do $$
begin
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;

  begin
    perform public.accept_eula('v-test-1');
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然能呼叫 accept_eula()';
  exception when sqlstate '42501' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：未登入呼叫 accept_eula() 被擋下（42501）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 4：anon 無 EXECUTE——授權面（has_function_privilege）與實際呼叫（角色
-- 切換）兩種驗法都做，比照 70_device_token_handover.sql／87_ 等既有慣例
-- （60_default_privileges.sql 的白名單通掃也會驗到，這裡是 feature 測試檔自己
-- 的正面對照，不是重複勞動）。
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon', 'public.accept_eula(text)', 'execute') then
    raise exception 'FAIL：anon 竟然對 accept_eula(text) 有 EXECUTE';
  end if;
  if not has_function_privilege('authenticated', 'public.accept_eula(text)', 'execute') then
    raise exception 'FAIL：authenticated 應該對 accept_eula(text) 有 EXECUTE';
  end if;
  raise notice 'ok：accept_eula(text) 授權面正確（authenticated 可執行、anon 不可執行）';
end;
$$;

begin;

do $$
begin
  set local role anon;
  begin
    perform public.accept_eula('v-test-1');
    raise exception 'FAIL：anon 角色竟然能呼叫 accept_eula()';
  exception when insufficient_privilege then
    null; -- ok（42501，沒有 EXECUTE grant）
  end;
  reset role;
  raise notice 'ok：anon 角色實際呼叫 accept_eula() 被擋下（insufficient_privilege）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 5：client 直接 UPDATE eula_accepted_version／eula_accepted_at 兩欄被拒
-- ——欄位級 grant 從未開放過這兩欄（見 migration 檔頭第 2 點），只能透過
-- accept_eula() 寫入。驗法比照 91_delete_account.sql §5 對 deletion_requested_at
-- 的既有慣例：兩欄各自單獨挨一次 UPDATE，並確認 display_name／avatar_url 這組
-- 既有可編輯欄位不受影響。
-- ---------------------------------------------------------------------------
begin;

do $$
declare
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_display_name text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    update public.profiles set eula_accepted_version = 'v-forged' where id = v_member;
    raise exception 'FAIL：authenticated 直接 UPDATE profiles.eula_accepted_version 竟然成功';
  exception when sqlstate '42501' then
    null; -- ok
  end;

  begin
    update public.profiles set eula_accepted_at = now() where id = v_member;
    raise exception 'FAIL：authenticated 直接 UPDATE profiles.eula_accepted_at 竟然成功';
  exception when sqlstate '42501' then
    null; -- ok
  end;

  -- 既有可編輯欄位不受這次收斂影響（同 91_delete_account.sql §5 的既有驗法）
  update public.profiles set display_name = 'EULA 測試改名' where id = v_member;
  reset role;

  select display_name into v_display_name from public.profiles where id = v_member;
  if v_display_name <> 'EULA 測試改名' then
    raise exception 'FAIL：display_name 直接 UPDATE 沒有真的落地（%）', v_display_name;
  end if;

  raise notice 'ok：eula_accepted_version／eula_accepted_at 直接 UPDATE 皆被拒（42501），display_name 仍可正常編輯';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 6：冪等——同版本重複呼叫不報錯，eula_accepted_at 更新為最新一次。
--
-- 這裡刻意**不**用單一 begin/rollback：`now()` 是 transaction timestamp，同一
-- 個交易內兩次呼叫拿到的時間戳完全相同，測不出「更新為最新一次」（開發期間
-- 實測撞過：兩次呼叫間插了 `pg_sleep(0.01)`，`eula_accepted_at` 仍然完全相等）。
-- 改用兩個各自獨立、真的 COMMIT 的敘述（比照
-- `105_suspension_and_registrations.sql` 場景 11 對同一個 `now()` 語意的既有
-- 處理方式），用一張暫存表在兩次呼叫之間傳遞第一次的時間戳；收尾另外把寫入的
-- 資料復原，不留殘留給後續測試檔。
-- ---------------------------------------------------------------------------
update public.app_settings set eula_version = 'v-test-1', updated_at = now() where id = true;

create temporary table ls197_idempotent_probe (t timestamptz);

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.accept_eula('v-test-1');

  reset role;

  -- 存進暫存表要以 postgres 身分（temp table 是 postgres 建的，authenticated
  -- 沒有 grant）——先 reset role 再寫，不是漏切角色。
  insert into ls197_idempotent_probe (t)
  select eula_accepted_at from public.profiles
   where id = 'a0000000-0000-4000-8000-000000000001';
end;
$$;

select pg_sleep(0.01);  -- 確保第二次的 now() 時間戳嚴格更晚，不是靠巧合分辨

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.accept_eula('v-test-1');  -- 冪等：同版本重複呼叫不應報錯

  reset role;
end;
$$;

do $$
declare
  v_first timestamptz;
  v_second timestamptz;
  v_version text;
begin
  select t into v_first from ls197_idempotent_probe limit 1;
  select eula_accepted_version, eula_accepted_at into v_version, v_second
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000001';

  if v_version <> 'v-test-1' then
    raise exception 'FAIL：重複呼叫後 eula_accepted_version 應仍是 v-test-1，實際 %', v_version;
  end if;
  if v_second <= v_first then
    raise exception 'FAIL：重複呼叫後 eula_accepted_at 應該更新為更晚的時間（第一次 %、第二次 %）', v_first, v_second;
  end if;

  raise notice 'ok：同版本重複呼叫 accept_eula() 不報錯，eula_accepted_at 更新為最新一次（冪等）';
end;
$$;

drop table ls197_idempotent_probe;

-- 清理：上面全部是真的 COMMIT，這裡把寫入的資料復原，不留殘留給後續測試檔
-- （比照 105_suspension_and_registrations.sql 場景 11 收尾的既有慣例）。
update public.profiles set eula_accepted_version = null, eula_accepted_at = null
 where id = 'a0000000-0000-4000-8000-000000000001';

rollback;

-- ---------------------------------------------------------------------------
-- 場景 7（額外，非票面六案，回歸保護）：停權者仍可呼叫 accept_eula()——同意
-- 條款不是內容寫入，理由同 delete_my_account() 對停權的豁免（migration 檔頭
-- 第 3 點）。這不是票面要求的六案之一，但這是本票一個關鍵、容易被之後的
-- private.enforce_not_suspended() 擴大範圍時意外破壞的設計決策，補上機械保護。
-- ---------------------------------------------------------------------------
begin;

update public.app_settings set eula_version = 'v-test-1', updated_at = now() where id = true;
update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  v_accepted_version text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.accept_eula('v-test-1');

  select eula_accepted_version into v_accepted_version from public.profiles
   where id = 'a0000000-0000-4000-8000-000000000002';
  if v_accepted_version <> 'v-test-1' then
    raise exception 'FAIL：被停權的使用者呼叫 accept_eula() 之後 eula_accepted_version 沒有正確寫入';
  end if;

  reset role;
  raise notice 'ok：被停權的使用者仍能成功呼叫 accept_eula()（同意條款不是內容寫入，PLAN §10-B 豁免同一組理由）';
end;
$$;

rollback;
