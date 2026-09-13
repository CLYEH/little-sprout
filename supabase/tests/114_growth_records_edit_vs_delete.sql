-- LS-258（DB 測試小債清倉 1，項 2；來源 LS-255 merge-review R1 informational i3，
-- Linear comment `6c5f0c40`）—— growth_records 補 `*_edit_vs_delete_*` 併發回歸
-- 測試，同形狀表 diaries／albums／comments／children 皆已有（`supabase/tests/
-- concurrency/*_edit_vs_delete_*.sql` 四件組，用兩個真的並行 psql session）。
--
-- growth_records 這裡刻意**不**比照那四件組另開 setup/s1/s2/verify 四個檔案：
-- LS-255 merge-review R1（`d5981139`）已經用兩個真正並行的 psql session＋
-- pg_sleep 手動驗證過這兩個情境，行為正確（「軟刪勝出，無 lost update」／
-- 「兩筆皆落地，無錯誤、無死鎖」），R1 判定「行為正確、缺的是 gate」，不是
-- 「行為有疑慮、需要真並發才測得出來」。本檔要釘住的是**最終狀態不變量**，不是
-- 鎖本身的阻塞時序——這兩者對 growth_records 是分開的：
--   - 情境 (a) 的不變量（「已被軟刪的紀錄，作者事後編輯一律無效，deleted_by 仍
--     正確歸屬」）由 PostgreSQL 對 UPDATE 命令自動套用 SELECT policy
--     （`growth_records_select` 的 `deleted_at is null`）保證——不論兩個操作是
--     真正並行還是先後發生，作者的 UPDATE 在 owner 的軟刪 commit 之後永遠只會
--     命中 0 列，這個保證與時序無關，用先後發生的單一 session 一樣測得出來
--     （本機實測核對過：`delete_growth_record` 先 commit 之後，`upsert_
--     growth_record` 拿到跟 R1 兩個真並行 session 逐字相同的 42501 與終態）。
--   - 情境 (b) 的不變量（「同 child 同日兩筆皆存活，分頁走訪不漏」）是 INSERT
--     對 INSERT，兩者互不衝突、沒有鎖可言，先後發生跟真正並行的最終狀態必然
--     一致。
--
-- Mutation 自證（LS-258，開發期間本機手動驗證，已改回原狀）：把
-- `growth_records_deletion_attribution` trigger（LS-57 共用函式，掛在 migration
-- 第 4 段）暫時 drop 掉，重跑情境 (a) —— 作者編輯仍然是 42501（不變，RLS 的
-- SELECT policy 過濾與這支 trigger 無關），但終態的 `deleted_by` 從 owner 變成
-- NULL（`FAIL：owner 軟刪後 deleted_by 應為 owner，實際 <NULL>`）——因為
-- `delete_growth_record()` 本身的 UPDATE 只寫 `deleted_at = now()`，`deleted_by`
-- 的歸屬完全靠這支 trigger 補上；drop 掉之後斷言由綠轉紅。`supabase db reset`
-- 還原（重新套用 migration）後重跑，斷言恢復綠。證明這個斷言真的在測這支共用
-- trigger 有沒有正確掛在 growth_records 上，不是恆綠空案。
\set ON_ERROR_STOP on

-- ===========================================================================
-- (a) 作者編輯 vs owner 軟刪：owner 軟刪先落地，作者事後（含跨交易）呼叫
--     upsert_growth_record 編輯內容必須無效（42501），終態內容未被改動、
--     deleted_at／deleted_by 維持 owner 軟刪時寫入的值。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_id uuid;
  v_row public.growth_records%rowtype;
  v_edit_failed boolean := false;
  v_edit_succeeded boolean := false;
begin
  -- 作者（member）建一筆
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, '原始備註')).id
    into v_id;
  reset role;

  -- owner 軟刪（先落地並 commit 等效——同一交易內 owner 的呼叫已對後續可見，
  -- 不需要真的跨 session 才能觀察這個不變量，見檔頭說明）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_growth_record(v_id);
  reset role;

  -- 作者事後嘗試編輯內容：必須無效（42501）
  --
  -- merge-review R1 minor-1：不在 `begin ... exception when others` 同一個 block
  -- 裡就地 `raise exception`——那句 raise 會被自己緊接著的 `when others` 接住
  -- （sqlstate 變成 P0001），讓「守則破了、真的改到了」這個最重要的失敗模式，被
  -- 誤判成「錯誤碼不是 42501」印出（reviewer 用 M2 拿掉 policy 的 `deleted_at is
  -- null` 實跑到這個訊息陷阱）。改成 perform 成功只設旗標，離開 block 之後才
  -- raise，讓兩種失敗各自印出正確訊息。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_growth_record(v_id, v_child, current_date, 99.0, null, null, '作者想改');
    v_edit_succeeded := true;
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：owner 軟刪之後作者編輯應拿到 42501，實際 %', sqlstate;
    end if;
    v_edit_failed := true;
  end;
  reset role;

  if v_edit_succeeded then
    raise exception 'FAIL：owner 軟刪之後，作者竟然還能編輯內容成功';
  end if;
  if not v_edit_failed then
    raise exception 'FAIL：作者編輯應該要失敗，卻沒有進入例外分支';
  end if;

  -- 終態核對：內容未被改動、deleted_at 已寫入、deleted_by 正確歸屬 owner
  -- （這格會被上方「Mutation 自證」的 drop trigger 動作打紅——見檔頭說明）。
  select g.* into v_row from public.growth_records g where g.id = v_id;
  if v_row.note <> '原始備註' then
    raise exception 'FAIL：owner 軟刪先動之後，作者無效的編輯竟然改動了內容（note=%）', v_row.note;
  end if;
  if v_row.deleted_at is null then
    raise exception 'FAIL：owner 軟刪之後 deleted_at 竟然是 NULL';
  end if;
  if v_row.deleted_by is distinct from v_owner then
    raise exception 'FAIL：owner 軟刪後 deleted_by 應為 owner，實際 %', v_row.deleted_by;
  end if;

  raise notice 'ok：owner 軟刪先落地，作者事後編輯無效（42501），內容／deleted_at／deleted_by 皆維持軟刪時的終態';
end;
$$;

rollback;

-- ===========================================================================
-- (b) 同 child 同日並發 insert：owner／member 兩位貢獻者對同一個孩子、同一天各
--     自新增一筆成長紀錄，兩筆都必須存活（無唯一約束衝突、無互相覆蓋），
--     `list_growth_records` 用小分頁走訪必須合計取到兩筆、無重複無遺漏。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_day date := current_date;
  v_id_owner uuid;
  v_id_member uuid;
  v_page1 uuid[];
  v_last public.growth_records;
  v_page2 uuid[];
  v_all uuid[];
begin
  -- owner 與 member 同一天各建一筆（先後發生等效於並行——INSERT 對 INSERT
  -- 沒有鎖可言，見檔頭說明；LS-255 merge-review R1 已用真正並行的兩個 session
  -- 驗過同一情境，終態一致）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id_owner := (public.upsert_growth_record(null, v_child, v_day, 71.0, null, null, 'owner 同日這筆')).id;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id_member := (public.upsert_growth_record(null, v_child, v_day, 72.0, null, null, 'member 同日這筆')).id;
  reset role;

  if v_id_owner = v_id_member then
    raise exception 'FAIL：owner／member 同日各自新增，id 竟然相同';
  end if;

  -- 兩筆都存活（deleted_at is null，走一般 SELECT 讀）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if (select count(*) from public.growth_records where id in (v_id_owner, v_id_member)) <> 2 then
    raise exception 'FAIL：同 child 同日兩筆應該皆存活可見，實際只讀到 %',
      (select count(*) from public.growth_records where id in (v_id_owner, v_id_member));
  end if;

  -- list_growth_records 用 p_limit=1 逼出兩頁，合計必須走訪到兩筆、無重複無遺漏
  select array_agg(g.id) into v_page1
    from public.list_growth_records(v_child, 1, null, null) g;
  if array_length(v_page1, 1) <> 1 then
    raise exception 'FAIL：page1（p_limit=1）應為 1 筆，實際 %', array_length(v_page1, 1);
  end if;

  select g.* into v_last
    from public.list_growth_records(v_child, 1, null, null) g;

  select array_agg(g.id) into v_page2
    from public.list_growth_records(v_child, 100, v_last.measured_on, v_last.id) g;

  select array_agg(distinct x) into v_all
    from unnest(v_page1 || coalesce(v_page2, array[]::uuid[])) as x;

  if not (v_id_owner = any(v_all) and v_id_member = any(v_all)) then
    raise exception 'FAIL：list_growth_records 分頁走訪合計沒有涵蓋同日兩筆（owner=%／member=%，實際 %）',
      v_id_owner, v_id_member, v_all;
  end if;
  if array_length(v_page1, 1) + coalesce(array_length(v_page2, 1), 0) <> array_length(v_all, 1) then
    raise exception 'FAIL：list_growth_records 分頁走訪出現重複（page1=% page2=% 去重後 %）',
      v_page1, v_page2, v_all;
  end if;
  reset role;

  raise notice 'ok：同 child 同日 owner／member 各一筆皆存活，list_growth_records 小分頁走訪合計兩筆、無重複無遺漏';
end;
$$;

rollback;
