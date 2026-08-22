-- LS-6：預設授權（default privileges）的收斂
--
-- 為什麼要有這一關：Supabase 的 public schema 預設會把新建資料表的 ALL 權限
-- 自動授給 anon / authenticated。init_schema 逐表 revoke 只管得到「當下已存在的表」，
-- 下一個 migration 建的表會在 CREATE 完成的瞬間就對未登入者全開，而新表預設沒有 RLS。
-- 這種洞不會有人察覺（沒有錯誤訊息、沒有失敗的測試），只會在資料外洩時才知道。
--
-- 同理，schema private 的函式建立時預設 `grant execute to public`，
-- 而 authenticated 是 PUBLIC 的一員又持有 schema private 的 USAGE，
-- 等於任何登入者都能直接呼叫 SECURITY DEFINER 的 trigger 函式。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. 新建的資料表對 anon / authenticated 不得有任何權限
-- ---------------------------------------------------------------------------
do $$
declare
  v_role text;
  v_priv text;
begin
  create table public.ls6_default_priv_probe (id int primary key);

  foreach v_role in array array['anon', 'authenticated'] loop
    foreach v_priv in array array[
      'select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger'
    ] loop
      if has_table_privilege(v_role, 'public.ls6_default_priv_probe', v_priv) then
        raise exception
          'FAIL default privileges：migration 之後新建的表對 % 仍有 % 權限 —— 未來的新表會在沒有 RLS 的情況下全開',
          v_role, v_priv;
      end if;
    end loop;
  end loop;

  raise notice 'ok default privileges：新建的表對 anon/authenticated 沒有任何 table 權限';
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. schema private 的函式：trigger 函式不對外，policy 用的集合函式照常可用
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn text;
begin
  -- SECURITY DEFINER 的 trigger 函式：登入者直接呼叫沒有任何正當用途
  foreach v_fn in array array[
    'private.add_creator_as_owner()',
    'private.enforce_family_has_owner()',
    'private.feed_sync_albums()',
    'private.feed_sync_media()',
    'private.feed_sync_diaries()',
    'private.media_storage_sync()'
  ] loop
    if has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 可以直接執行 %（SECURITY DEFINER trigger 函式）', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 可以直接執行 %', v_fn;
    end if;
  end loop;
  raise notice 'ok：private 的 trigger 函式對 anon/authenticated 都沒有 EXECUTE';

  -- 正向對照：policy 依賴的集合函式必須留給 authenticated，否則整組 RLS 判斷會噴權限錯
  foreach v_fn in array array[
    'private.family_ids()',
    'private.owned_family_ids()',
    'private.contributor_family_ids()',
    'private.uploadable_family_ids()',
    'private.peer_profile_ids()'
  ] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 失去 % 的 EXECUTE，所有 RLS policy 都會失效', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 不該有 % 的 EXECUTE', v_fn;
    end if;
  end loop;
  raise notice 'ok：policy 用的五支集合函式只有 authenticated 可執行';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. schema private 裡「每一支」函式都不得對 PUBLIC 開放 EXECUTE
--
-- 這一段是 migration 註解裡說的那個 gate，取代做不到的
-- `alter default privileges in schema private revoke execute on functions from public`
-- （schema 範圍的 default privileges 只能加不能減內建預設，那句話是 no-op）。
-- 逐支列舉而不是只驗現有那幾支：日後的 migration 新增 private 函式若忘了補 revoke，
-- 函式的 proacl 會是 NULL（＝PUBLIC 可執行），這裡就會失敗。
-- authenticated 持有 schema private 的 USAGE，PUBLIC 開放等於登入者可直接呼叫。
-- ---------------------------------------------------------------------------
do $$
declare
  v_leaky text;
begin
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_leaky
    from pg_proc p
   where p.pronamespace = 'private'::regnamespace
     and (
       p.proacl is null   -- NULL = 內建預設 = PUBLIC 可執行
       or exists (
         select 1 from aclexplode(p.proacl) a
          where a.grantee = 0 and a.privilege_type = 'EXECUTE'  -- grantee 0 = PUBLIC
       )
     );

  if v_leaky is not null then
    raise exception
      'FAIL：schema private 的這些函式對 PUBLIC 開放 EXECUTE —— %（新增 private 函式後要補 revoke execute … from public）',
      v_leaky;
  end if;
  raise notice 'ok：schema private 的每一支函式都沒有對 PUBLIC 開放 EXECUTE';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. LS-15：新建的 sequence 對 anon / authenticated 不得有任何權限
--
-- init_schema.sql 的 default privileges 收斂只涵蓋 tables；本測試證明
-- 20260822120300_harden_default_privileges.sql 把 sequences 這個洞也補上了。
-- ---------------------------------------------------------------------------
do $$
declare
  v_role text;
  v_priv text;
begin
  create sequence public.ls15_default_priv_probe_seq;

  foreach v_role in array array['anon', 'authenticated'] loop
    foreach v_priv in array array['usage', 'select', 'update'] loop
      if has_sequence_privilege(v_role, 'public.ls15_default_priv_probe_seq', v_priv) then
        raise exception
          'FAIL default privileges：migration 之後新建的 sequence 對 % 仍有 % 權限',
          v_role, v_priv;
      end if;
    end loop;
  end loop;

  -- 正向對照（reviewer 點名）：驗證環境若整組角色權限剛好都是空的（例如漏跑
  -- Supabase 的 default privileges 佈建），上面的斷言會「假綠」——因為 anon/
  -- authenticated 本來就沒有任何權限，不是被本 migration 收回的。這裡反過來
  -- 確認 service_role（migration 沒有動它）仍保有預設權限，證明探針量到的是
  -- 「真的有一份 default privileges 存在、只是 anon/authenticated 被拿掉了」。
  foreach v_priv in array array['usage', 'select', 'update'] loop
    if not has_sequence_privilege('service_role', 'public.ls15_default_priv_probe_seq', v_priv) then
      raise exception
        'FAIL 正向對照：新建的 sequence 對 service_role 應仍有 % 權限，卻沒有——驗證環境可能整組空白，上面 anon/authenticated 的斷言可能是假綠',
        v_priv;
    end if;
  end loop;

  raise notice 'ok default privileges：新建的 sequence 對 anon/authenticated 沒有任何權限、service_role 權限不受影響';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. LS-15：新建的 function 對 anon / authenticated 不得有 EXECUTE
--
-- 收斂後採「per-RPC 顯式 grant」慣例：新函式預設不可執行，要開放給前端呼叫
-- 必須像 public.register_device_token() 一樣逐支明確 grant（下一段回歸驗證）。
-- ---------------------------------------------------------------------------
do $$
declare
  v_role text;
begin
  create function public.ls15_default_priv_probe_fn()
  returns void language sql as $body$ select 1 $body$;

  foreach v_role in array array['anon', 'authenticated'] loop
    if has_function_privilege(v_role, 'public.ls15_default_priv_probe_fn()', 'execute') then
      raise exception
        'FAIL default privileges：migration 之後新建的 function 對 % 仍有 EXECUTE 權限',
        v_role;
    end if;
  end loop;

  -- 正向對照（同上一段的理由）：service_role 的 EXECUTE 是本 migration 特意保留
  -- （見 harden_default_privileges.sql 的 `grant execute on functions to
  -- service_role`），驗證環境若整組空白會讓這裡也假綠，故一併確認。
  if not has_function_privilege('service_role', 'public.ls15_default_priv_probe_fn()', 'execute') then
    raise exception
      'FAIL 正向對照：新建的 function 對 service_role 應仍有 EXECUTE，卻沒有——驗證環境可能整組空白，上面 anon/authenticated 的斷言可能是假綠';
  end if;

  raise notice 'ok default privileges：新建的 function 對 anon/authenticated 沒有 EXECUTE、service_role 不受影響';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5b. LS-15 F2 回歸：public 以外的 schema，service_role 的預設 EXECUTE 不因
-- 全域 revoke 而消失
--
-- harden_default_privileges.sql 對 functions 的收斂用了不指定 schema 的全域
-- revoke（見該檔案第 3 段註解）；這連帶拿掉了 service_role 過去「經由 PUBLIC」
-- 拿到的隱式執行權，因此該檔案補了一句同樣不指定 schema 的
-- `grant execute on functions to service_role`。這裡在 public 以外新建一個
-- schema 驗證：新函式對 service_role 仍可執行、對 anon/authenticated 仍不可執行。
-- ---------------------------------------------------------------------------
do $$
begin
  drop schema if exists ls15_other_schema_probe cascade;
  create schema ls15_other_schema_probe;

  create function ls15_other_schema_probe.probe_fn()
  returns void language sql as $body$ select 1 $body$;

  if has_function_privilege('anon', 'ls15_other_schema_probe.probe_fn()', 'execute') then
    raise exception 'FAIL：public 以外的 schema，新函式對 anon 仍有 EXECUTE';
  end if;
  if has_function_privilege('authenticated', 'ls15_other_schema_probe.probe_fn()', 'execute') then
    raise exception 'FAIL：public 以外的 schema，新函式對 authenticated 仍有 EXECUTE';
  end if;
  if not has_function_privilege('service_role', 'ls15_other_schema_probe.probe_fn()', 'execute') then
    raise exception 'FAIL：public 以外的 schema，新函式對 service_role 失去了 EXECUTE——全域 revoke 的副作用沒有被 service_role 的全域 grant 蓋回去';
  end if;

  raise notice 'ok：public 以外的 schema，新函式對 service_role 仍可執行、對 anon/authenticated 仍不可執行';
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. LS-15：public.rls_auto_enable()（event trigger 支撐函式）對三者皆不可執行
--
-- 這是 LS-14 雲端 security advisors 點名的 WARN：它只是 event trigger 的內部支撐函式，
-- 不該有任何 API 呼叫者（anon／authenticated），也不該對 PUBLIC 開放。
--
-- 條件式斷言：這支函式只存在於雲端 Supabase 專案，官方 `supabase` CLI 的本機開發
-- 映像（CI db job 用的那份）沒有它（PR #17 CI 實測撞 42883：
-- run https://github.com/CLYEH/little-sprout/actions/runs/32565795483）。
-- 本機不存在時只能誠實跳過（notice，不是斷言通過）；雲端側的收權由 LS-15
-- 部署後的 advisors 複掃驗證，不是這裡的斷言範圍。
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is null then
    raise notice '略過：public.rls_auto_enable() 在本驗證環境不存在（官方 supabase CLI 本機開發映像沒有這支函式，只存在於雲端專案）——收權斷言留待雲端部署後的 advisors 複掃';
    return;
  end if;

  if has_function_privilege('anon', 'public.rls_auto_enable()', 'execute') then
    raise exception 'FAIL：anon 可以執行 public.rls_auto_enable()';
  end if;
  if has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute') then
    raise exception 'FAIL：authenticated 可以執行 public.rls_auto_enable()';
  end if;
  if exists (
    select 1 from pg_proc p, aclexplode(p.proacl) a
     where p.oid = 'public.rls_auto_enable()'::regprocedure
       and a.grantee = 0  -- 0 = PUBLIC
       and a.privilege_type = 'EXECUTE'
  ) then
    raise exception 'FAIL：public.rls_auto_enable() 仍對 PUBLIC 開放 EXECUTE';
  end if;

  raise notice 'ok：public.rls_auto_enable() 對 anon/authenticated/PUBLIC 都不可執行';
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. 回歸：既有 RPC public.register_device_token() 的顯式 grant 不受本次收斂影響
--
-- LS-15 的 functions default privileges 收斂只管「未來新函式」；這支函式是
-- 20260822120200_rls_policies.sql 已經逐支 grant 過的既有函式，兩者是獨立的 ACL。
-- （supabase/tests/70_device_token_handover.sql 也驗過這件事；這裡是直接對照。）
-- ---------------------------------------------------------------------------
do $$
begin
  if not has_function_privilege('authenticated',
       'public.register_device_token(text, text)', 'execute') then
    raise exception 'FAIL 回歸：authenticated 應仍可執行 register_device_token，卻沒有——functions default privileges 收斂波及了既有的顯式 grant';
  end if;
  if has_function_privilege('anon', 'public.register_device_token(text, text)', 'execute') then
    raise exception 'FAIL：anon 不該可以執行 register_device_token';
  end if;
  raise notice 'ok 回歸：register_device_token 對 authenticated 仍可執行、anon 仍不可執行';
end;
$$;

rollback;
