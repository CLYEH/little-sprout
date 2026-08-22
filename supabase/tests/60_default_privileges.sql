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
--
-- 兩段斷言各自的依據（review round 2 要求：每條斷言都要註明是靠我們自己的
-- migration，還是靠環境佈建）：
--   - 下面的「anon/authenticated 無權限」：依據是 harden_default_privileges.sql
--     的 `revoke all on sequences from anon, authenticated`，任何環境都成立——
--     但單靠這條無法證明「revoke 真的做了事」，因為一個完全空白的驗證環境
--     （沒佈建任何 default privileges）也會讓 anon/authenticated 天生無權限，
--     跟被我們收回是兩回事，斷言結果卻一樣，所以需要下面的正向對照。
--   - 正向對照（service_role 仍有權限）：**曾經**依據 Supabase 佈建的假設
--     （雲端 \ddp 實查如此），但 review round 2 在 PR #17 CI 的 db job 用官方
--     supabase CLI 本機開發映像實測到：那份映像的佈建根本不把 sequences 的
--     default 權限給 service_role（run 32566229308 紅燈）——雲端與官方本機映像
--     的佈建不一樣，屬於環境相依假設，不可靠。已改為由
--     harden_default_privileges.sql 自己的 `grant all on sequences to
--     service_role` 保證，現在這條斷言只跟「我們自己下了那句 grant 沒有」有關，
--     跟測試在哪個環境跑無關（下方 mutation test 會把那句 grant 拿掉驗證）。
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

  foreach v_priv in array array['usage', 'select', 'update'] loop
    if not has_sequence_privilege('service_role', 'public.ls15_default_priv_probe_seq', v_priv) then
      raise exception
        'FAIL 正向對照：新建的 sequence 對 service_role 應仍有 % 權限，卻沒有——harden_default_privileges.sql 的 service_role grant 可能被拿掉或改壞了',
        v_priv;
    end if;
  end loop;

  raise notice 'ok default privileges：新建的 sequence 對 anon/authenticated 沒有任何權限、service_role 權限由我們自己的 migration 保證';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. LS-15：新建的 function 對 anon / authenticated 不得有 EXECUTE
--
-- 收斂後採「per-RPC 顯式 grant」慣例：新函式預設不可執行，要開放給前端呼叫
-- 必須像 public.register_device_token() 一樣逐支明確 grant（下一段回歸驗證）。
--
-- 兩段斷言各自的依據：
--   - 「anon/authenticated 無 EXECUTE」：依據 harden_default_privileges.sql 的
--     兩句 revoke（schema 範圍 + 全域），任何環境都成立，但同第 4 段的理由，
--     單靠這條測不出「revoke 有沒有真的生效」，需要下面的正向對照。
--   - 正向對照（service_role 仍可 EXECUTE）：依據
--     harden_default_privileges.sql 自己的 `grant execute on functions to
--     service_role`（不指定 schema的全域寫法），不依賴 Supabase 佈建對
--     functions 是否原本就給 service_role EXECUTE——不管平台佈建有沒有給，
--     這句 grant 都會補上，所以這條斷言只跟我們自己下了那句 grant 沒有有關。
--     （這支跟 sequences 那支不一樣：sequences 沒有「PUBLIC 內建預設」這個
--     問題，所以第 4 段的 service_role grant 是新補的；functions 因為要處理
--     PUBLIC baseline 而必須全域 revoke，才連帶需要這句全域 grant 補償——
--     兩者需要各自的 grant，不是同一個洞。）
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

  if not has_function_privilege('service_role', 'public.ls15_default_priv_probe_fn()', 'execute') then
    raise exception
      'FAIL 正向對照：新建的 function 對 service_role 應仍有 EXECUTE，卻沒有——harden_default_privileges.sql 的 service_role grant 可能被拿掉或改壞了';
  end if;

  raise notice 'ok default privileges：新建的 function 對 anon/authenticated 沒有 EXECUTE、service_role 由我們自己的 migration 保證';
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
--
-- 依據：三個角色的結果都由 harden_default_privileges.sql 的全域 revoke/grant
-- 保證（這三句本來就不指定 schema，效果理當涵蓋 public 以外的任何 schema）——
-- 這一段就是在直接驗證「全域」兩個字是真的，不是只驗 public 剛好也對。
-- 不依賴任何平台佈建假設：新開的 schema 沒有人事先佈建過 default privileges，
-- 結果完全由我們自己那三句全域語句決定。
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
--
-- 依據：函式「存不存在」是環境事實，測不了、也不用測——本段只斷言「存在的話
-- 有沒有被收權」，這部分完全由 harden_default_privileges.sql 那段 guard 過的
-- revoke 決定，不是平台佈建假設（前提只有「函式存在」這一件事是環境給的，
-- 收權與否是我們自己的 migration 做的）。
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
--
-- 依據：這是 Postgres 的機械事實，不是平台佈建假設——default privileges 只影響
-- 「之後新建立」的物件，不會回頭改寫已存在物件的 proacl；register_device_token
-- 是 LS-15 這個 migration 執行之前就已存在的函式，其 ACL 不可能被本票的任何一句
-- ALTER DEFAULT PRIVILEGES 動到。任何環境下都該通過。
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

-- ---------------------------------------------------------------------------
-- 8. LS-34：public schema 的 SECURITY DEFINER RPC 逐支登記授權（白名單列舉）
--
-- 第 3 段只列舉 schema private 的函式，管的是「trigger 函式不對外」；public 的
-- SECURITY DEFINER RPC 是給前端呼叫的 API 邊界，授權方式不同（LS-15 定下的
-- per-RPC 顯式 grant 慣例），漏 grant 的後果也不同：呼叫端會直接炸掉，但目前
-- 沒有任何測試會指出「你忘了 grant」（LS-33 review 觀察，見票面追加事項）。
--
-- 這裡反過來做「白名單」而不是逐支挑著測：
--   - 清單內的 RPC：authenticated 必須可 EXECUTE、anon 與 PUBLIC 都不可。
--   - 出現清單外的 public definer 函式：直接 FAIL——新增 public RPC 必須先來這裡
--     登記，否則這道 gate 抓不到「忘了收斂授權」這件事，形同虛設。
--
-- 白名單（8 支，行為各自已由對應 ticket 的測試逐支驗證過；這裡只驗授權面）：
--   register_device_token          LS-6／LS-15（70_device_token_handover.sql、本檔第 7 段）
--   其餘 7 支（create_invite…）    LS-33（80_join_approval.sql §11）
--
-- 排除 public.rls_auto_enable()：Supabase 平台自帶的 event trigger 支撐函式（見第 6 段），
-- 不是本專案的 API RPC，本機開發映像沒有它，其收權已由第 6 段獨立驗證，不重複登記。
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn text;
  v_whitelist oid[] := array[
    'public.create_invite(uuid, text, timestamptz, integer)'::regprocedure::oid,
    'public.request_join(text)'::regprocedure::oid,
    'public.approve_join(uuid)'::regprocedure::oid,
    'public.reject_join(uuid)'::regprocedure::oid,
    'public.withdraw_join(uuid)'::regprocedure::oid,
    'public.list_join_requests()'::regprocedure::oid,
    'public.get_my_join_request()'::regprocedure::oid,
    'public.register_device_token(text, text)'::regprocedure::oid
  ];
  v_unknown text;
begin
  foreach v_fn in array array[
    'public.create_invite(uuid, text, timestamptz, integer)',
    'public.request_join(text)',
    'public.approve_join(uuid)',
    'public.reject_join(uuid)',
    'public.withdraw_join(uuid)',
    'public.list_join_requests()',
    'public.get_my_join_request()',
    'public.register_device_token(text, text)'
  ] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 不能執行白名單 RPC %，呼叫端會炸卻沒有測試指出原因', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 可以執行白名單 RPC %（未登入者能操作這支 RPC）', v_fn;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = v_fn::regprocedure and a.grantee = 0
                  and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL：白名單 RPC % 仍對 PUBLIC 開放 EXECUTE', v_fn;
    end if;
  end loop;
  raise notice 'ok：白名單內的 8 支 public SECURITY DEFINER RPC 授權皆正確（authenticated 可執行、anon／PUBLIC 不可）';

  -- 白名單外的 public definer 函式：直接 FAIL（新 RPC 必須先來這裡登記）
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_unknown
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosecdef
     and p.oid <> all(v_whitelist)
     and p.oid is distinct from to_regprocedure('public.rls_auto_enable()');

  if v_unknown is not null then
    raise exception
      'FAIL：public schema 出現清單外的 SECURITY DEFINER RPC —— %（新增 public RPC 必須先到本檔第 8 段的白名單登記授權，否則漏 grant 時呼叫端會炸但沒有測試指出原因）',
      v_unknown;
  end if;
  raise notice 'ok：public schema 沒有清單外的 SECURITY DEFINER RPC';
end;
$$;

rollback;
