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
--
-- ---------------------------------------------------------------------------
-- Mutation 自證（LS-84，開發期用本機 Supabase CLI 映像手動驗證，非本檔自動執行；
-- 套用後已改回原狀）：
--   M1：在一個 begin…rollback 交易內對 `private.enforce_child_not_deleted()`
--       （merge-reviewer PR #124 review F4 點名的漏網函式——原本不在第 2 段任何
--       名單裡，改成通掃後才會被涵蓋）追加 `grant execute ... to authenticated`
--       → 第 2 段的通掃斷言變紅（實測：v_leaky 精準點名
--       `private.enforce_child_not_deleted()`，訊息「schema private 這些函式
--       （不在允許清單／例外清單內）對 authenticated 或 anon 開放了 EXECUTE」）；
--       `revoke execute ... from authenticated` 還原後再次執行變綠。證明通掃真的
--       會抓到名單外的 grant，不是恆綠的空案。
-- ---------------------------------------------------------------------------

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
-- 2. schema private 的函式：通掃＋允許清單（LS-84 收斂 merge-reviewer PR #124
--    review F4——結構性假綠）
--
-- LS-84 之前這裡是手寫列舉「不得對 authenticated/anon 開放的 private trigger
-- 函式」，名單外的函式（已確認漏列 private.enforce_child_not_deleted()／
-- private.enforce_children_family_immutable()）若日後被 grant execute 給
-- authenticated，這裡與第 3 段（只管 PUBLIC，管不到直接 grant 給 authenticated）
-- 都掃不到，三道 gate 全綠——是結構性假綠，不是這兩支剛好被漏記。
--
-- 改法：對 schema private「全體」函式通掃，扣掉 v_allow_fns（RLS policy／storage
-- policy 求值時必須留給 authenticated 的函式，正向對照見下方迴圈）與 v_exceptions
-- （額外的顯式例外，目前為空；若日後新增例外，必須在此附理由），剩下的每一支都
-- 斷言 authenticated／anon 皆無 EXECUTE。日後任何新的 private 函式，只要沒有被
-- 明確登記進允許清單，一律會被這道通掃檢查到——不必再靠人手動記得補列舉。
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn text;
  v_allow_fns text[] := array[
    'private.family_ids()',
    'private.owned_family_ids()',
    'private.contributor_family_ids()',
    'private.uploadable_family_ids()',
    'private.peer_profile_ids()',
    'private.is_media_object_path(text)',
    -- LS-169 R2（M1）：同 is_media_object_path，掛在 media_bucket_update／
    -- media_bucket_delete 的頭像分支上，policy 求值時要被 authenticated 呼叫。
    'private.is_avatar_object_path(text)',
    -- LS-149：封鎖過濾共用的兩支輔助函式。private.blocked_pairs() 被
    -- albums_select／comments_select 兩條 RLS policy 直接呼叫（policy 以 authenticated
    -- 身分求值，同其餘集合函式的理由）；private.feed_item_actor_id(feed_kind,uuid) 被
    -- get_family_timeline（security invoker）呼叫，同一個理由——沒有這支 EXECUTE，
    -- 呼叫者封鎖過人時整條時間軸查詢會直接噴權限錯。
    'private.blocked_pairs()',
    'private.feed_item_actor_id(public.feed_kind,uuid)',
    -- LS-179：families_select／content_reports_select／join_requests_select
    -- 三條 policy（R2 merge-review m1／m2 補齊後三條都會用到）直接呼叫
    -- private.caller_is_active()／private.family_is_active(uuid)（policy 以
    -- authenticated 身分求值，同其餘集合函式的理由）。registrations_open()
    -- 只從 enforce_registrations_open() trigger 內部呼叫（以 postgres 身分
    -- 執行），不需要登記在這裡。
    'private.caller_is_active()',
    'private.family_is_active(uuid)'
  ];
  v_exceptions text[] := array[]::text[];  -- 目前無例外；若新增，必須附理由註解
  v_allow_oids oid[];
  v_exc_oids oid[];
  v_swept int;
  v_leaky text;
begin
  select array_agg(f::regprocedure::oid) into v_allow_oids from unnest(v_allow_fns) as f;
  select coalesce(array_agg(f::regprocedure::oid), array[]::oid[])
    into v_exc_oids from unnest(v_exceptions) as f;

  -- fail-open 防呆（比照第 9 段）：v_swept 是通掃出來要檢查的函式數量，
  -- 若為 0（例如允許清單／例外清單意外涵蓋了全部函式，或這段查詢本身寫壞了），
  -- 代表這道檢查形同沒跑，必須直接 FAIL，不能悄悄地對全體 private 函式視而不見。
  select count(*) into v_swept
    from pg_proc p
   where p.pronamespace = 'private'::regnamespace
     and p.oid <> all (v_allow_oids)
     and p.oid <> all (v_exc_oids);

  if v_swept = 0 then
    raise exception 'FAIL：§2 通掃結果為 0 支 private 函式——允許清單／例外清單意外涵蓋了全部函式，或這段檢查本身寫壞了，防呆攔截';
  end if;

  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_leaky
    from pg_proc p
   where p.pronamespace = 'private'::regnamespace
     and p.oid <> all (v_allow_oids)
     and p.oid <> all (v_exc_oids)
     and (
       has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')
     );

  if v_leaky is not null then
    raise exception
      'FAIL：schema private 這些函式（不在允許清單／例外清單內）對 authenticated 或 anon 開放了 EXECUTE —— %（新增 private 函式若要開放給 authenticated，先到本段 v_allow_fns 登記並附理由；純內部用的 trigger／輔助函式不必登記，維持通掃覆蓋）',
      v_leaky;
  end if;
  raise notice 'ok：schema private 通掃 % 支非允許清單函式，authenticated／anon 皆無 EXECUTE', v_swept;

  -- 正向對照：policy 依賴的函式必須留給 authenticated，否則整組 RLS 判斷會噴權限錯。
  -- LS-40 的 private.is_media_object_path(text) 不是集合函式（是路徑規約的判斷式，
  -- 給 storage.objects 的 INSERT／UPDATE WITH CHECK 用），但同樣是「policy 求值時會被
  -- 呼叫、少了 EXECUTE 整條上傳路徑就炸」的東西，所以登記在同一份清單裡。
  foreach v_fn in array v_allow_fns loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 失去 % 的 EXECUTE，所有 RLS policy 都會失效', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 不該有 % 的 EXECUTE', v_fn;
    end if;
  end loop;
  raise notice 'ok：允許清單內的 % 支 private 函式只有 authenticated 可執行', array_length(v_allow_fns, 1);
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

  -- merge-reviewer PR #60 review N3（第 2 輪）：第 8 段把「清單外函式」的掃描範圍
  -- 從「只看 SECURITY DEFINER」放寬到「public schema 的所有函式」之後，這支探針
  -- 函式若留著不清，會被第 8 段誤判成一支沒登記的未知 RPC（它本來就只是這裡的
  -- 拋棄式測試道具，從來不是 API 的一部分）。用完即丟，不要留到後面的段落去。
  drop function public.ls15_default_priv_probe_fn();
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
-- 8. LS-34：public schema 的 RPC 逐支登記授權（白名單列舉）
--
-- 第 3 段只列舉 schema private 的函式，管的是「trigger 函式不對外」；public 的 RPC
-- 是給前端呼叫的 API 邊界，授權方式不同（LS-15 定下的 per-RPC 顯式 grant 慣例），
-- 漏 grant 的後果也不同：呼叫端會直接炸掉，但目前沒有任何測試會指出「你忘了 grant」
-- （LS-33 review 觀察，見票面追加事項）。
--
-- 這裡反過來做「白名單」而不是逐支挑著測，分兩張表：
--   - v_definer_rpcs：SECURITY DEFINER 的 RPC。authenticated 必須可 EXECUTE、anon 與
--     PUBLIC 都不可，且必須是 SECURITY DEFINER＋search_path 收斂（LS-34 review F2：
--     這兩條防護原本只在 80_join_approval.sql §11 驗過，且只涵蓋那裡的 7 支——
--     register_device_token 的 definer／search_path 至今零測試覆蓋。統一併到這裡，
--     白名單內每一支都驗，不再兩份清單各管各的、互相漂移；80_ §11 已縮成指路註解）。
--   - v_invoker_rpcs（merge-reviewer PR #60 review N3，第 2 輪）：SECURITY INVOKER
--     的 RPC，目前只有 get_family_timeline 一支。授權面驗法跟 definer 那組一樣
--     （authenticated 可執行、anon／PUBLIC 不可），但**不**驗「必須是 SECURITY
--     DEFINER」——這支函式刻意是 invoker（依賴 feed_items 既有的 RLS 做隔離，不需要
--     繞過 RLS），硬套 definer 檢查只會逼著它去符合一個不該套用在它身上的規則。
--   - v_service_role_rpcs（LS-151 R2／LS-153 R3，併入 development 時 union；
--     LS-172 追加 claim_notification_events／notification_recipients）：
--     SECURITY DEFINER 但**不對 authenticated 開放**、只給 service_role 執行的
--     public RPC——finalize_account_deletion（LS-151，Edge Function delete-account
--     用 service_role 呼叫）、purge_storage_queue_mark_failed（LS-153，
--     purge-storage Edge Function 用）、claim_notification_events／
--     notification_recipients（LS-172，push-dispatch Edge Function 用；票文字面
--     寫 `private.` 前綴，落地時改放 public schema——理由見
--     `20260904095205_push_dispatch.sql` 檔頭第 1 段：`private` schema 不在
--     `supabase/config.toml` 的 `[api] schemas` 內，Edge Function 用
--     `supabase-js` 的 `.rpc()` 完全叫不到），皆非前端直接呼叫的 API 邊界。授權方向與
--     另外兩組相反：authenticated／anon／PUBLIC 都必須「不可執行」，service_role
--     必須「可執行」；definer／search_path 收斂的檢查與 v_definer_rpcs 相同。
--
-- N3 的問題背景：第 1 輪把 get_family_timeline 從白名單裡整支排除（因為它不是
-- definer），順帶把它排除到了下面「清單外函式」那段掃描的**輸入條件**之外——那段
-- 原本只掃 `p.prosecdef` 為真的函式，於是 get_family_timeline 對這道 gate 完全隱形：
-- reviewer 實測，手動對它 `grant execute ... to anon` 之後，60_ 與 85_ 兩個測試檔
-- 都還是全綠。修法：
--   a) 為它單獨補 EXECUTE 正負斷言（下面 v_invoker_rpcs 那段迴圈）；
--   b) 把「清單外函式」的掃描條件從「`p.prosecdef` 為真」放寬到「public schema 的
--      所有函式」，白名單改成 v_definer_rpcs ∪ v_invoker_rpcs 兩張表的聯集——這樣
--      任何未登記的 public 函式，不論是不是 definer，都逃不過這道 gate。
--
-- 排除 public.rls_auto_enable()：Supabase 平台自帶的 event trigger 支撐函式（見第 6 段），
-- 不是本專案的 API RPC，本機開發映像沒有它，其收權已由第 6 段獨立驗證，不重複登記。
--
-- 單一清單來源（LS-34 review F3，N3 沿用同一個原則）：v_definer_rpcs／v_invoker_rpcs
-- 是唯一手寫的白名單，oid 版本（給「清單外函式」那段用）在 begin 之後由它們 cast
-- 導出——不分開各自宣告一份 oid 陣列，漏改其中一份會讓兩段檢查看到不同的清單而
-- 悄悄漏測（fail-open）。若清單裡寫錯函式簽名或該函式不存在，下面 array_agg 那句
-- cast 會直接噴出含函式簽名的錯誤，訊息可讀。
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn text;
  v_definer_rpcs text[] := array[
    'public.create_invite(uuid, text, timestamptz, integer)',
    'public.request_join(text)',
    'public.approve_join(uuid)',
    'public.reject_join(uuid)',
    'public.withdraw_join(uuid)',
    'public.list_join_requests()',
    'public.get_my_join_request()',
    'public.register_device_token(text, text)',
    'public.create_diary_entry(uuid, uuid[], text, date)',
    'public.update_diary_entry(uuid, text, date, uuid[])',
    'public.set_diary_deleted(uuid, boolean)',
    'public.set_album_deleted(uuid, boolean)',
    'public.set_album_children(uuid, uuid[])',
    'public.set_comment_deleted(uuid, boolean)',
    'public.create_comment(uuid, text, uuid, text)',
    'public.update_comment(uuid, text)',
    'public.toggle_reaction(uuid, text, uuid)',
    'public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)',
    'public.create_child(uuid, text, date, text)',
    'public.update_child(uuid, text, date, text)',
    'public.set_child_deleted(uuid, boolean)',
    -- LS-149
    'public.report_content(uuid, text, uuid, text)',
    'public.block_user(uuid, uuid)',
    'public.unblock_user(uuid, uuid)',
    'public.remove_content_as_owner(text, uuid)',
    -- LS-143
    'public.delete_my_account()'
  ];
  v_invoker_rpcs text[] := array[
    'public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)',
    'public.get_reaction_counts(uuid, text, uuid[])',
    'public.list_children(uuid)',
    'public.get_family_quota(uuid)'  -- LS-149：純讀取，依賴既有 families_select RLS
  ];
  -- v_service_role_rpcs（union，LS-151 R2／R3＋LS-153 R3——兩票各自新增這個
  -- 分類，併入 development 時合併成一個陣列）：public schema 裡不是給
  -- authenticated 呼叫、只給 service_role 呼叫的 RPC——Edge Function
  -- （supabase/functions/*）用 service_role key 走 PostgREST 的 `.rpc()`，只碰得到
  -- public schema（見 purge_storage_queue 表註解的同一個理由），這類函式因此不能
  -- 放 private，但也不該像 v_definer_rpcs 那樣要求 authenticated 可執行——授權面
  -- 反過來：authenticated／anon 皆無 EXECUTE，只有 service_role 有。按函式名字母
  -- 順序排列。
  v_service_role_rpcs text[] := array[
    'public.claim_notification_events(integer)',  -- LS-172：push-dispatch 用
    'public.finalize_account_deletion(uuid)',  -- LS-151：delete-account 用
    'public.notification_recipients(uuid[])',  -- LS-172：push-dispatch 用（R2 改批次簽章，見 migration 檔頭第 2 段）
    'public.purge_storage_queue_mark_failed(uuid[], text)'  -- LS-153：purge-storage 用
  ];
  v_whitelist oid[];
  v_unknown text;
begin
  select array_agg(f::regprocedure::oid)
    into v_whitelist
    from unnest(v_definer_rpcs || v_invoker_rpcs || v_service_role_rpcs) as f;

  foreach v_fn in array v_definer_rpcs loop
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
    -- definer 函式的兩個標準防護：以擁有者身分執行 + search_path 收斂（F2：原本只在
    -- 80_join_approval.sql §11 驗、且不含 register_device_token，統一併到這裡）
    if not exists (select 1 from pg_proc p
                    where p.oid = v_fn::regprocedure and p.prosecdef
                      and p.proconfig @> array['search_path=""']) then
      raise exception 'FAIL：白名單 RPC % 不是 SECURITY DEFINER 或沒有 set search_path = ''''', v_fn;
    end if;
  end loop;
  raise notice
    'ok：白名單內的 % 支 public SECURITY DEFINER RPC 授權與 definer／search_path 硬化皆正確（authenticated 可執行、anon／PUBLIC 不可）',
    array_length(v_definer_rpcs, 1);

  -- N3：invoker RPC 只驗授權面（authenticated 可、anon／PUBLIC 不可），不驗
  -- definer／search_path——這支刻意是 invoker，硬套 definer 檢查會誤判成失敗。
  foreach v_fn in array v_invoker_rpcs loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 不能執行白名單 RPC %，呼叫端會炸卻沒有測試指出原因', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 可以執行白名單 RPC %（未登入者能操作這支 RPC——即使它是 security invoker，未登入呼叫仍不該被允許）', v_fn;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = v_fn::regprocedure and a.grantee = 0
                  and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL：白名單 RPC % 仍對 PUBLIC 開放 EXECUTE', v_fn;
    end if;
  end loop;
  raise notice
    'ok：白名單內的 % 支 public SECURITY INVOKER RPC 授權正確（authenticated 可執行、anon／PUBLIC 不可）——N3',
    array_length(v_invoker_rpcs, 1);

  -- service_role-only RPC——授權方向與上面兩組相反，authenticated／anon／
  -- PUBLIC 都不可執行，只有 service_role 可執行；同樣要求 SECURITY DEFINER＋
  -- search_path 收斂（reason 同 v_definer_rpcs：呼叫者身分之外沒有 RLS 保護，
  -- definer 才能跨家庭寫 purge_storage_queue／family_members 等表）。
  foreach v_fn in array v_service_role_rpcs loop
    if has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：authenticated 竟然可以執行 service_role-only RPC %', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL：anon 竟然可以執行 service_role-only RPC %', v_fn;
    end if;
    if not has_function_privilege('service_role', v_fn, 'execute') then
      raise exception 'FAIL：service_role 不能執行 service_role-only RPC %，呼叫端會炸卻沒有測試指出原因', v_fn;
    end if;
    if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = v_fn::regprocedure and a.grantee = 0
                  and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL：service_role-only RPC % 仍對 PUBLIC 開放 EXECUTE', v_fn;
    end if;
    if not exists (select 1 from pg_proc p
                    where p.oid = v_fn::regprocedure and p.prosecdef
                      and p.proconfig @> array['search_path=""']) then
      raise exception 'FAIL：service_role-only RPC % 不是 SECURITY DEFINER 或沒有 set search_path = ''''', v_fn;
    end if;
  end loop;
  raise notice
    'ok：白名單內的 % 支 public service_role-only RPC 授權正確（authenticated／anon 皆不可執行、service_role 可執行、非 PUBLIC）',
    array_length(v_service_role_rpcs, 1);

  -- 清單外的 public 函式：直接 FAIL（新 RPC 必須先來這裡登記）。N3：掃描條件從
  -- 「p.prosecdef 為真」放寬到「public schema 的所有函式」，不再只顧得到 definer——
  -- 這正是 get_family_timeline 曾經對這道 gate 隱形的原因（它不是 definer，原本的
  -- 條件把它跟任何未來的 invoker RPC 一起漏掉了）。
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_unknown
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.oid <> all(v_whitelist)
     and p.oid is distinct from to_regprocedure('public.rls_auto_enable()');

  if v_unknown is not null then
    raise exception
      'FAIL：public schema 出現清單外的函式 —— %（新增 public RPC 必須先到本檔第 8 段的白名單登記授權，否則漏 grant 時呼叫端會炸但沒有測試指出原因；不分是不是 SECURITY DEFINER，N3 之後 invoker RPC 也逃不過這道 gate）',
      v_unknown;
  end if;
  raise notice 'ok：public schema 沒有清單外的函式（definer／invoker 皆已涵蓋）';
end;
$$;

-- 9. LS-40：schema private 的函式必須 SECURITY DEFINER＋search_path 收斂，例外逐支登記
--
-- 前提對帳（LS-40 review F8 的宣稱與實況）：review 說 supabase/tests 裡 grep 不到
-- prosecdef／proconfig。實況是**有的**——第 8 段（LS-34 併入）就在驗，
-- 但它的範圍是 `public` schema 的 RPC 白名單。private schema 這一側在此之前確實
-- 沒有任何 definer／search_path 的機械檢查：第 3 段只管「不對 PUBLIC 開放 EXECUTE」，
-- 第 2 段只管「authenticated 有沒有 EXECUTE」，兩者都不看函式怎麼硬化。
-- 所以 review 的結論（要補）是對的，理由（grep 不到）不對，兩件事分開記。
--
-- 為什麼 private 這一側需要這道 gate：schema private 的函式幾乎都是 policy 與 trigger
-- 用的，它們要讀 family_members 這種自己也帶 RLS 的表，非 definer 不可；而 definer
-- 沒有 `set search_path = ''` 就會被呼叫端的 search_path 挾持。這兩件事現在靠人記得，
-- 漏掉不會有任何錯誤訊息。
--
-- 例外清單（invoker 函式）——刻意的，不是漏網：
--   private.is_media_object_path(text)：只對參數做 regex，不碰任何資料庫物件，
--   沒有 search_path 挾持的面；而帶 SET 子句的 SQL 函式**無法被規劃器 inline**，
--   會變成每列一次真正的函式呼叫。它掛在 storage.objects 的 INSERT／UPDATE
--   WITH CHECK 上，逐列跑，所以刻意留成 invoker 且不加 SET 以換取 inline。
--   （新增 private 函式若也要走這條例外，必須先來這裡登記並寫明理由。）
--   private.is_avatar_object_path(text)：LS-169 R2，同上一條理由，逐字一樣的形狀
--   （純 regex、掛在 media_bucket_update／media_bucket_delete 的 WITH CHECK／USING 上）。
--   private.deletion_bypass_active()：LS-179 R2（MAJOR-2），只讀一個交易級 GUC
--   （`current_setting`），不碰任何資料庫物件，沒有 search_path 挾持的面，同
--   is_media_object_path 的理由。
--   private.enforce_deletion_bypass()：LS-179 R2，只呼叫 `set_config` 設同一個
--   GUC，一樣不碰任何資料庫物件；只被 SECURITY DEFINER 的 delete_my_account()
--   呼叫（以 postgres 身分執行，物件擁有者恆有權限，不需要靠自己是 definer 才能
--   運作），是否收 search_path 對它的正確性沒有影響。
-- ---------------------------------------------------------------------------
do $$
declare
  -- 單一清單來源（比照第 8 段）：oid 版本由文字版 cast 導出，清單裡的函式不存在時
  -- 這句 cast 會直接噴出含簽名的錯誤，不會無聲漂移。
  v_exceptions text[] := array[
    'private.is_media_object_path(text)',
    'private.is_avatar_object_path(text)',
    'private.deletion_bypass_active()',
    'private.enforce_deletion_bypass()'
  ];
  v_exc_oids oid[];
  v_leaky text;
  v_stale text;
begin
  -- coalesce 是必要的不是裝飾：v_exceptions 若被清空，array_agg 對零列取值會回 NULL，
  -- 下面的 `p.oid <> all (v_exc_oids)` 遇到 NULL 陣列恆得 NULL，WHERE 篩不出任何一列
  -- ——例外清單空了，這段檢查反而對全體 private 函式靜默通過（fail-open）。
  select coalesce(array_agg(f::regprocedure::oid), array[]::oid[])
    into v_exc_oids from unnest(v_exceptions) as f;

  -- 清單外的每一支都必須 definer + search_path=""。
  -- coalesce 是必要的不是裝飾：proconfig 為 NULL（＝沒有任何 SET 子句）時
  -- `NULL @> array[...]` 是 NULL，`prosecdef and NULL` 對 definer 函式會得到 NULL，
  -- WHERE 篩不出來——正好漏掉「是 definer 但忘了收 search_path」這個最該抓的情況。
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_leaky
    from pg_proc p
   where p.pronamespace = 'private'::regnamespace
     and p.oid <> all (v_exc_oids)
     and not (p.prosecdef
              and coalesce(p.proconfig, array[]::text[]) @> array['search_path=""']);

  if v_leaky is not null then
    raise exception
      'FAIL：schema private 的這些函式不是 SECURITY DEFINER 或沒有 set search_path = '''' —— %（policy／trigger 函式要讀帶 RLS 的表必須是 definer；definer 沒收 search_path 會被呼叫端挾持。若是刻意的 invoker 例外，先到本檔第 9 段登記並寫明理由）',
      v_leaky;
  end if;

  -- 反向對照：例外清單裡的函式如果其實已經是 definer 了，代表清單過期沒清掉
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_stale
    from pg_proc p
   where p.oid = any (v_exc_oids) and p.prosecdef;

  if v_stale is not null then
    raise exception
      'FAIL：例外清單裡的這些函式其實已經是 SECURITY DEFINER 了，清單過期——請從第 9 段的 v_exceptions 移除：%',
      v_stale;
  end if;

  raise notice
    'ok：schema private 的函式除了登記在案的 % 支 invoker 例外，都是 SECURITY DEFINER＋search_path 收斂',
    coalesce(array_length(v_exceptions, 1), 0);
end;
$$;

rollback;

begin;

-- ---------------------------------------------------------------------------
-- 10. LS-57 R2（N1/N2 根治）：albums／diaries／comments 三表的 deleted_at／
--     deleted_by／family_id 三欄，authenticated 皆不得有 UPDATE 欄位級權限
--
-- 為什麼要有這一關：20260825040000_deletion_attribution.sql 的 R1 版本只靠
-- enforce_deletion_attribution() trigger 擋「建立者直接 UPDATE 竄改 deleted_by／
-- family_id」，merge-reviewer PR #98 review R2（N1/N2）實測出 albums 的整表
-- UPDATE grant 讓這個防線繞得過去——trigger 只在「這句 UPDATE 真的執行到」的
-- 當下才能判斷，判斷不了「呼叫端到底想在同一句 UPDATE 裡塞什麼」。R2 改成欄位級
-- grant 收斂，這裡機械驗證收斂真的生效——不是等 88_ 用實際 UPDATE 語句間接測出
-- 來，是直接查 pg_attribute 的 ACL。
--
-- diaries／comments 兩張表的整表 UPDATE 早在 LS-48／LS-58 就已經對 authenticated
-- revoke（RPC-only），這三欄理論上本來就摸不到；這裡仍然逐欄驗證，跟 migration
-- 加的「雙保險」REVOKE 對應，也讓「這三欄是治理欄位」這件事在測試裡有一個機械
-- 斷言可以看，不必回頭讀 migration 註解才知道。
-- ---------------------------------------------------------------------------
do $$
declare
  v_leaky text;
  v_probe record;
begin
  -- 三表三欄，authenticated 對 update 皆須是 false。
  for v_probe in
    select * from (values
      ('albums', 'deleted_at'), ('albums', 'deleted_by'), ('albums', 'family_id'),
      ('diaries', 'deleted_at'), ('diaries', 'deleted_by'), ('diaries', 'family_id'),
      ('comments', 'deleted_at'), ('comments', 'deleted_by'), ('comments', 'family_id')
    ) as t(tbl, col)
  loop
    if has_column_privilege('authenticated', format('public.%I', v_probe.tbl), v_probe.col, 'update') then
      v_leaky := coalesce(v_leaky || '、', '') || format('%s.%s', v_probe.tbl, v_probe.col);
    end if;
  end loop;

  if v_leaky is not null then
    raise exception
      'FAIL：authenticated 對這些欄位仍有 UPDATE 權限，N1/N2 的欄位級 grant 收斂沒有生效 —— %',
      v_leaky;
  end if;
  raise notice 'ok：albums／diaries／comments 的 deleted_at／deleted_by／family_id 九個欄位，authenticated 皆無 UPDATE 權限（LS-57 R2 N1/N2）';
end;
$$;

-- 正向對照：albums 的內容欄位（title／cover_media_id）不受影響，建立者仍能直接
-- 編輯——欄位級收斂不能誤傷這兩欄，否則 §3「albums」hybrid 模式的建立者直接
-- UPDATE 路徑整個失效。LS-121：child_id 已移出 albums（改用 album_children
-- 連結表，寫入路徑是 set_album_children RPC，不是這裡驗的直接 UPDATE），不再
-- 是這份正向對照要涵蓋的欄位。
do $$
declare
  v_missing text;
  v_probe record;
begin
  for v_probe in
    select * from (values ('title'), ('cover_media_id')) as t(col)
  loop
    if not has_column_privilege('authenticated', 'public.albums', v_probe.col, 'update') then
      v_missing := coalesce(v_missing || '、', '') || v_probe.col;
    end if;
  end loop;

  if v_missing is not null then
    raise exception
      'FAIL：albums 的這些內容欄位，authenticated 應該仍有 UPDATE 權限，卻被誤收回了 —— %',
      v_missing;
  end if;
  raise notice 'ok：albums 的 title／cover_media_id 兩個內容欄位，authenticated 仍有 UPDATE 權限（欄位級收斂沒有誤傷 hybrid 模式的建立者直接編輯路徑）';
end;
$$;

rollback;
