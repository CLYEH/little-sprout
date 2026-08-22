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

rollback;
