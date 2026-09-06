-- LS-224 — 正式站 advisors 健檢收口，範圍 1/2/3 的機械斷言
--
-- 三段各自對應一個 orchestrator 2026-09-06 20:23 對正式站 get_advisors（唯讀）跑出來的
-- 發現，逐段獨立、互不依賴：
--   §1 function_search_path_mutable：private／public schema 所有函式都要有 search_path，
--      例外逐支登記（跟 60_default_privileges.sql §9 是互補關係，不是重複——§9 驗的是
--      「private schema、且必須同時是 definer」，範圍窄一層；這裡不管 definer/invoker，
--      也涵蓋 public schema，直接對應 advisor 的判準本身：有沒有 search_path）。
--   §2 rls_enabled_no_policy：三張「刻意只給 service_role」的表，把「anon／authenticated
--      零權限＋RLS 開」這個前提釘成機械斷言（來源：LS-213／LS-222 sweeper 對
--      orphan_scan_cursor 已提過同型缺口，這裡補上這三張表的版本）。
--   §3 authenticated_security_definer_function_executable：public schema 內
--      SECURITY DEFINER 且 authenticated 可執行的函式集合，逐支列白名單並跟
--      docs/API.md §3 對照。
--
-- ---------------------------------------------------------------------------
-- Mutation 自證（開發期用本機 Supabase CLI 映像手動驗證，非本檔自動執行；套用後已
-- 改回原狀，比照 60_default_privileges.sql 頂端 LS-84 的既有慣例）：
--   M1（§1）：在一個 begin…rollback 交易內對 private.enforce_deletion_bypass() 執行
--       `alter function private.enforce_deletion_bypass() reset search_path;`
--       → §1 變紅，實測訊息：「FAIL：這些函式沒有 set search_path = '' ——
--       private.enforce_deletion_bypass()（function_search_path_mutable advisor
--       WARN；……）」，精準點名該函式。rollback 還原後再次執行 §1 變綠（本檔已
--       merge 進 run.sh 的全套重跑也確認綠）。
--   M2（§3）：在一個 begin…rollback 交易內對非白名單的 SECURITY DEFINER 函式
--       `grant execute on function public.finalize_account_deletion(uuid) to authenticated;`
--       （這支是 v_service_role_rpcs 成員，本來就不該對 authenticated 開放——選它
--       而不是票文建議的 private.deletion_bypass_active() 是因為 §3 的掃描範圍明確
--       限定 public schema，private 函式的洩漏本來就已經被
--       60_default_privileges.sql §2 的通掃盯著，不是本段要驗的判準）
--       → §3 變紅，實測訊息：「FAIL：public schema 出現清單外、對 authenticated
--       開放 EXECUTE 的 SECURITY DEFINER 函式（advisor
--       authenticated_security_definer_function_executable）——
--       finalize_account_deletion(uuid)（……）」，精準點名該函式。rollback 還原後
--       再次執行 §3 變綠。
--   兩次 mutation 的完整終端輸出見票 LS-224 handoff。
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. function_search_path_mutable：private／public schema 通掃，例外逐支登記
-- ---------------------------------------------------------------------------
do $$
declare
  v_exceptions text[] := array[
    -- LS-224（沿用 LS-40／LS-169 R2 已審過的權衡，完整理由見新 migration
    -- 20260906123430_advisors_hardening_search_path.sql 檔頭與
    -- 60_default_privileges.sql §9 對應例外段落）：這兩支是 language sql、security
    -- invoker、純 regex（不碰任何資料庫物件，沒有 search_path 挾持的面），直接掛在
    -- storage.objects 三條 policy 的 USING／WITH CHECK 上逐列求值——加
    -- set search_path 會讓規劃器無法 inline，退化成每列一次真正的函式呼叫，對這條
    -- 每次媒體／頭像上傳都會走到的寫入熱路徑是真實代價，且沒有對應的安全收益。
    -- 刻意不修，advisor 對這兩支的 WARN 是已知、可接受的殘留（若要推翻這個決定，
    -- 先去 60_default_privileges.sql §9 與 is_avatar_object_path 的 migration 檔頭
    -- 討論，不要只改這裡的清單）。
    'private.is_media_object_path(text)',
    'private.is_avatar_object_path(text)'
  ];
  v_exc_oids oid[];
  v_swept int;
  v_leaky text;
begin
  select coalesce(array_agg(f::regprocedure::oid), array[]::oid[])
    into v_exc_oids from unnest(v_exceptions) as f;

  -- fail-open 防呆（比照 60_default_privileges.sql §2 的既有慣例）：v_swept 是
  -- 通掃出來要檢查的函式數量，若為 0，代表這道檢查形同沒跑，必須直接 FAIL。
  select count(*) into v_swept
    from pg_proc p
   where p.pronamespace in ('private'::regnamespace, 'public'::regnamespace)
     and p.oid <> all (v_exc_oids);

  if v_swept = 0 then
    raise exception 'FAIL：LS-224 §1 通掃結果為 0 支函式——例外清單意外涵蓋了全部函式，或這段檢查本身寫壞了，防呆攔截';
  end if;

  -- coalesce 是必要的不是裝飾：proconfig 為 NULL（沒有任何 SET 子句）時
  -- `NULL @> array[...]` 是 NULL，`not NULL` 也是 NULL，WHERE 篩不出來——正好漏掉
  -- 「完全沒有 SET 子句」這個最該抓的情況（同 60_default_privileges.sql §9 的既有教訓）。
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_leaky
    from pg_proc p
   where p.pronamespace in ('private'::regnamespace, 'public'::regnamespace)
     and p.oid <> all (v_exc_oids)
     and not (coalesce(p.proconfig, array[]::text[]) @> array['search_path=""']);

  if v_leaky is not null then
    raise exception
      'FAIL：這些函式沒有 set search_path = '''' —— %（function_search_path_mutable advisor WARN；若是刻意的效能權衡例外，先到本段 v_exceptions 登記並寫明理由，不要悄悄跳過）',
      v_leaky;
  end if;

  raise notice
    'ok：schema private／public 通掃 % 支函式（扣掉 % 支登記例外：is_media_object_path／is_avatar_object_path），皆已 set search_path',
    v_swept, coalesce(array_length(v_exceptions, 1), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. rls_enabled_no_policy：三張「刻意只給 service_role」的表
-- ---------------------------------------------------------------------------
do $$
declare
  v_probe record;
  v_leaky text;
  v_qualified text;
  v_role text;
  v_priv text;
begin
  for v_probe in
    select * from (values
      ('private', 'purge_runs'),
      ('public', 'notification_events'),
      ('public', 'purge_storage_queue')
    ) as t(schema_name, table_name)
  loop
    if not exists (
      select 1 from pg_class c
       where c.relname = v_probe.table_name
         and c.relnamespace = v_probe.schema_name::regnamespace
         and c.relrowsecurity
    ) then
      raise exception 'FAIL：%.% 沒有啟用 RLS（relrowsecurity 應為 true）', v_probe.schema_name, v_probe.table_name;
    end if;

    v_qualified := format('%I.%I', v_probe.schema_name, v_probe.table_name);
    foreach v_role in array array['anon', 'authenticated'] loop
      foreach v_priv in array array['select', 'insert', 'update', 'delete'] loop
        if has_table_privilege(v_role, v_qualified, v_priv) then
          v_leaky := coalesce(v_leaky || '、', '') || format('%s(%s,%s)', v_qualified, v_role, v_priv);
        end if;
      end loop;
    end loop;
  end loop;

  if v_leaky is not null then
    raise exception
      'FAIL：這些 RLS-no-policy 表對 anon／authenticated 仍有 table 權限，「僅 service_role」的前提不成立 —— %',
      v_leaky;
  end if;

  raise notice
    'ok：private.purge_runs／public.notification_events／public.purge_storage_queue 三張表皆已啟用 RLS，且 anon／authenticated 對 select/insert/update/delete 皆無權限（僅 service_role 存取）';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. authenticated_security_definer_function_executable：public schema 白名單
--
-- 單一清單來源提醒：這份 v_whitelist 跟 60_default_privileges.sql §8 的
-- v_definer_rpcs 描述的是同一組事實（public schema、SECURITY DEFINER、
-- authenticated 可執行的 RPC），但兩份清單分屬不同檔案（各自獨立的 psql -f
-- 執行、無法共用陣列變數），只能逐字同步維護——新增／移除這類 RPC 時兩處都要改。
-- 這裡刻意仍然自己重新掃一次（不是省略、直接信任 §8 已經測過），因為本段的
-- 「清單外函式」反向掃描條件（下面）跟 §8 不同：§8 的清單外掃描涵蓋
-- **所有** public 函式（不論是不是 definer、不論 authenticated 有沒有 EXECUTE），
-- 本段只鎖定 advisor 實際點名的判準——SECURITY DEFINER 且 authenticated 可
-- EXECUTE——範圍更貼近 docs/API.md §3 新增小節要對照的那份清單，兩者是互補的
-- 兩道防線，不是重複勞動。
-- ---------------------------------------------------------------------------
do $$
declare
  v_whitelist text[] := array[
    'public.accept_eula(text)',
    'public.approve_join(uuid)',
    'public.block_user(uuid, uuid)',
    'public.create_child(uuid, text, date, text)',
    'public.create_comment(uuid, text, uuid, text)',
    'public.create_diary_entry(uuid, uuid[], text, date)',
    'public.create_invite(uuid, text, timestamptz, integer)',
    'public.delete_my_account()',
    'public.get_my_join_request()',
    'public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)',
    'public.list_join_requests()',
    'public.register_device_token(text, text)',
    'public.reject_join(uuid)',
    'public.remove_content_as_owner(text, uuid)',
    'public.report_content(uuid, text, uuid, text)',
    'public.request_join(text)',
    'public.set_album_children(uuid, uuid[])',
    'public.set_album_deleted(uuid, boolean)',
    'public.set_child_deleted(uuid, boolean)',
    'public.set_comment_deleted(uuid, boolean)',
    'public.set_diary_deleted(uuid, boolean)',
    'public.toggle_reaction(uuid, text, uuid)',
    'public.transfer_ownership(uuid, uuid)',
    'public.unblock_user(uuid, uuid)',
    'public.update_child(uuid, text, date, text)',
    'public.update_comment(uuid, text)',
    'public.update_diary_entry(uuid, text, date, uuid[])',
    'public.withdraw_join(uuid)'
  ];
  v_oids oid[];
  v_fn text;
  v_leaky text;
begin
  -- 若清單裡寫錯函式簽名或該函式不存在，這句 cast 會直接噴出含函式簽名的錯誤，
  -- 不會無聲漂移（比照 60_default_privileges.sql §8 的既有慣例）。
  select array_agg(f::regprocedure::oid) into v_oids from unnest(v_whitelist) as f;

  -- 正向：白名單每一支都必須真的是 SECURITY DEFINER 且 authenticated 可執行。
  foreach v_fn in array v_whitelist loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL：白名單 RPC % 應對 authenticated 開放 EXECUTE，卻沒有——docs/API.md §3 白名單與實際 grant 不一致', v_fn;
    end if;
    if not exists (select 1 from pg_proc p where p.oid = v_fn::regprocedure and p.prosecdef) then
      raise exception 'FAIL：白名單 RPC % 應是 SECURITY DEFINER，卻不是——docs/API.md §3 白名單與實際定義不一致', v_fn;
    end if;
  end loop;

  -- 反向：public schema 內任何 SECURITY DEFINER 且 authenticated 可執行的函式，
  -- 不在白名單內就直接 FAIL——新 RPC 開放給 authenticated 前必須先到這裡登記，
  -- 同步更新 docs/API.md §3 的白名單小節與 60_default_privileges.sql §8。
  select string_agg(p.oid::regprocedure::text, '、' order by p.oid::regprocedure::text)
    into v_leaky
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'execute')
     and p.oid <> all (v_oids);

  if v_leaky is not null then
    raise exception
      'FAIL：public schema 出現清單外、對 authenticated 開放 EXECUTE 的 SECURITY DEFINER 函式（advisor authenticated_security_definer_function_executable）—— %（新增 RPC 必須先到本段白名單、docs/API.md §3 對應小節、60_default_privileges.sql §8 三處登記）',
      v_leaky;
  end if;

  raise notice
    'ok：public schema 內 authenticated 可執行的 SECURITY DEFINER RPC 恰好是白名單內的 % 支，與 docs/API.md §3 對照一致',
    array_length(v_whitelist, 1);
end;
$$;

rollback;
