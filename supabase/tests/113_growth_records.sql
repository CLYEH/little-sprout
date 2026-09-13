-- LS-255（LS-250 後端先行）— growth_records 表／RLS／三支 RPC 驗收
--
-- 對應 supabase/migrations/20260913065021_growth_records.sql 的每一項決定。角色矩陣
-- 沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3、
-- child=2a000000-0000-4000-8000-000000000001（小芽）；非本家庭成員用 B 家 owner
-- （b1）代表。
--
-- 每個編號段各自用 begin;/rollback; 包起來（同 85_diaries_timeline.sql／
-- 95_children_backend.sql 的既有慣例），段內對資料的任何變更 rollback 會自動還原。
--
-- Mutation 自證（LS-255，開發期用本機 Supabase CLI 映像手動驗證，非本檔自動執行；
-- 套用後已改回原狀）：把 `growth_records_update` policy 的 USING/WITH CHECK 暫時
-- 改成 `using (true) with check (true)`（比照拿掉這條 policy 的效果——放寬到任何人
-- 都能改任何一列）之後重跑本檔，§3「owner 不能編輯別人內容」與「離開家庭之後不能
-- 再編輯」兩段斷言皆由綠轉紅（`FAIL：owner 竟然可以直接編輯別人的成長紀錄內容`／
-- `FAIL：已離開家庭的前作者竟然還能編輯內容`）；改回原本的 policy 定義後重跑，
-- 兩段斷言恢復全綠。證明這兩段斷言真的在測 RLS 本身，不是恆綠的空案。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. RLS 讀：家庭成員（owner／member／viewer）皆可讀未刪的列；非本家庭讀不到；
--    已軟刪的列對所有人（含作者本人）都讀不到——見 migration 檔頭第 2 段裁量。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_role uuid;
  v_count int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 70.5, 8.2, 43.0, '第一次量')).id
    into v_id;
  reset role;

  -- owner／member／viewer 都讀得到（不分角色）
  foreach v_role in array array[v_owner, v_member, v_viewer] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_role, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_count from public.growth_records where id = v_id;
    if v_count <> 1 then
      raise exception 'FAIL：% 呼叫讀取應看到 1 列，實際 %', v_role, v_count;
    end if;
    reset role;
  end loop;
  raise notice 'ok：owner／member／viewer 皆可讀到同家庭未刪的成長紀錄';

  -- 非本家庭成員讀不到（他家庭讀不到——票面驗收項）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.growth_records where id = v_id;
  if v_count <> 0 then
    raise exception 'FAIL：非本家庭成員（B 家 owner）竟然讀得到 A 家的成長紀錄';
  end if;
  reset role;
  raise notice 'ok：非本家庭成員讀不到（他家庭讀不到）';

  -- 軟刪之後，連作者本人（也是 owner）都讀不到
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_growth_record(v_id);
  select count(*) into v_count from public.growth_records where id = v_id;
  if v_count <> 0 then
    raise exception 'FAIL：軟刪之後，作者（也是 owner）本人竟然還讀得到這筆紀錄';
  end if;
  reset role;
  raise notice 'ok：軟刪之後任何角色（含作者本人）皆讀不到';
end;
$$;

rollback;

-- ===========================================================================
-- 2. RLS 新增：owner／member 可新增（author_id 必須是自己）；viewer 不行；
--    author_id 想指定成別人一律被 WITH CHECK 擋下。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_row public.growth_records%rowtype;
begin
  -- owner 能新增，欄位正確落地
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := public.upsert_growth_record(null, v_child, date '2026-01-01', 68.0, 7.8, null, '滿月量測');
  if v_row.family_id <> v_family or v_row.child_id <> v_child or v_row.author_id <> v_owner
     or v_row.height_cm <> 68.0 or v_row.weight_kg <> 7.8 or v_row.head_cm is not null
     or v_row.note <> '滿月量測' or v_row.deleted_at is not null then
    raise exception 'FAIL：owner 新增的成長紀錄欄位與參數不符';
  end if;
  reset role;

  -- member 能新增
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := public.upsert_growth_record(null, v_child, date '2026-02-01', null, 8.5, 44.0, null);
  if v_row.author_id <> v_member then
    raise exception 'FAIL：member 新增的成長紀錄 author_id 不是自己';
  end if;
  reset role;
  raise notice 'ok：owner／member 皆可新增成長紀錄，欄位正確落地';

  -- viewer 不能新增（PLAN §3）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null);
    raise exception 'FAIL：viewer 竟然可以新增成長紀錄';
  exception when insufficient_privilege then
    null;  -- ok（RLS 違反，42501）
  end;
  reset role;
  raise notice 'ok：viewer 無法新增成長紀錄（42501）';

  -- 直接 INSERT 指定 author_id 為別人，一律被 WITH CHECK 擋下
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.growth_records (family_id, child_id, author_id, measured_on, height_cm)
    values (v_family, v_child, v_member, current_date, 70.0);
    raise exception 'FAIL：owner 竟然能用別人的 author_id 直接 INSERT 成長紀錄';
  exception when insufficient_privilege then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：author_id 不是呼叫者本人時，直接 INSERT 一律被 WITH CHECK 擋下（42501）';
end;
$$;

rollback;

-- ===========================================================================
-- 3. RLS 更新（內容）：僅原作者本人；owner 不能編輯別人的（更新只限作者，票面
--    驗收項「非作者改不動」）；非本家庭成員不行；離開家庭之後前作者也不能再編輯
--    （`family_id in contributor_family_ids()` 是即時子查詢，不是靜態 author_id
--    比對——見 migration 檔頭第 0 段裁量）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_row public.growth_records%rowtype;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, date '2026-03-01', 72.0, 9.0, null, '原始備註')).id
    into v_id;
  reset role;

  -- Postgres 的 now() 在同一交易內是常數（transaction_timestamp 語意，同
  -- 88_deletion_attribution.sql 檔頭的既有說明）——insert／update 若在同一交易內
  -- 呼叫，created_at／updated_at 會拿到同一個值，測不出 updated_at 是否真的被
  -- 刷新。用 postgres 身分把 created_at 直接回填成一小時前（bypass 這張表沒有
  -- BEFORE UPDATE 檢查 created_at 的 trigger，直接寫入不受影響），讓 now() 與
  -- 回填後的 created_at 保證不同。
  update public.growth_records set created_at = now() - interval '1 hour' where id = v_id;

  -- 原作者（member）能編輯
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := public.upsert_growth_record(v_id, v_child, date '2026-03-02', 72.5, 9.1, 44.5, '改過的備註');
  if v_row.measured_on <> date '2026-03-02' or v_row.height_cm <> 72.5
     or v_row.weight_kg <> 9.1 or v_row.head_cm <> 44.5 or v_row.note <> '改過的備註' then
    raise exception 'FAIL：原作者編輯成長紀錄內容沒有生效';
  end if;
  if v_row.updated_at <= v_row.created_at then
    raise exception 'FAIL：編輯之後 updated_at 應晚於 created_at（updated_at=%，created_at=%）',
      v_row.updated_at, v_row.created_at;
  end if;
  reset role;
  raise notice 'ok：原作者可編輯自己的成長紀錄內容，updated_at 正確刷新';

  -- owner（非作者）不能編輯——「更新只限作者」，owner 不例外（票面驗收項）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_growth_record(v_id, v_child, current_date, 99.9, null, null, 'owner 想改');
    raise exception 'FAIL：owner 竟然可以直接編輯別人的成長紀錄內容';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：owner 編輯別人內容應拿到 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：owner 無法編輯非自己作者的成長紀錄內容（42501，非作者改不動）';

  -- 非本家庭成員不能編輯
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_growth_record(v_id, v_child, current_date, 99.9, null, null, '外人想改');
    raise exception 'FAIL：非本家庭成員竟然可以編輯這筆成長紀錄';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：非本家庭成員編輯應拿到 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：非本家庭成員無法編輯（42501）';

  -- 已離開家庭的前作者：不能再編輯（動態成員檢查，不是靜態 author_id 比對）
  delete from public.family_members where family_id = v_family and user_id = v_member;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_growth_record(v_id, v_child, current_date, 99.9, null, null, '離開後想改');
    raise exception 'FAIL：已離開家庭的前作者竟然還能編輯內容';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：已離開家庭的前作者編輯應拿到 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_member, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法再編輯（42501）——即時成員檢查，不是靜態 author_id 比對';
end;
$$;

rollback;

-- ===========================================================================
-- 4. 軟刪欄位的 GRANT 封閉：deleted_at／deleted_by／family_id／child_id／
--    author_id 對 authenticated 完全沒有 UPDATE 權限（不論表級或欄位級）——這是
--    「作者不能還原 owner 軟刪」的實際落地機制（票面驗收項），唯一寫入路徑是
--    delete_growth_record()。內容欄位＋updated_at 則應該有（正向對照，否則
--    upsert_growth_record 的更新分支會整支打不開）。
-- ===========================================================================
begin;

do $$
declare
  v_col text;
  v_leaky text;
begin
  foreach v_col in array array['deleted_at', 'deleted_by', 'family_id', 'child_id', 'author_id'] loop
    if has_column_privilege('authenticated', 'public.growth_records', v_col, 'update') then
      v_leaky := coalesce(v_leaky || '、', '') || v_col;
    end if;
  end loop;
  if v_leaky is not null then
    raise exception 'FAIL：authenticated 竟然對 growth_records 的這些治理欄位仍有 UPDATE 權限：%', v_leaky;
  end if;

  foreach v_col in array array['measured_on', 'height_cm', 'weight_kg', 'head_cm', 'note', 'updated_at'] loop
    if not has_column_privilege('authenticated', 'public.growth_records', v_col, 'update') then
      raise exception 'FAIL 正向對照：authenticated 應對 growth_records.% 有 UPDATE 權限，卻沒有——upsert_growth_record 的更新分支會打不開', v_col;
    end if;
  end loop;

  raise notice 'ok：deleted_at／deleted_by／family_id／child_id／author_id 五欄對 authenticated 完全沒有 UPDATE 權限；內容欄位＋updated_at 皆有（正向對照）';
end;
$$;

rollback;

begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_id uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null)).id into v_id;

  -- 直接 UPDATE deleted_at（軟刪方向）一律 42501——不論呼叫者是誰，包含 owner／作者
  begin
    update public.growth_records set deleted_at = now() where id = v_id;
    raise exception 'FAIL：owner 竟然可以直接 UPDATE deleted_at（軟刪 grant 收斂形同虛設）';
  exception when insufficient_privilege then
    null;  -- ok
  end;

  -- 直接 UPDATE deleted_at 想清空（還原方向，模擬「作者想還原 owner 軟刪」）同樣
  -- 42501——這正是票面「作者不能還原 owner 軟刪」的落地機制：grant 層完全封閉，
  -- 不必等到 RLS／trigger 才擋下。
  begin
    update public.growth_records set deleted_at = null where id = v_id;
    raise exception 'FAIL：竟然可以直接 UPDATE deleted_at 清成 NULL（作者不能還原 owner 軟刪的 grant 防線形同虛設）';
  exception when insufficient_privilege then
    null;  -- ok
  end;

  begin
    update public.growth_records set deleted_by = v_owner where id = v_id;
    raise exception 'FAIL：竟然可以直接 UPDATE deleted_by';
  exception when insufficient_privilege then
    null;  -- ok
  end;

  reset role;
  raise notice 'ok：deleted_at／deleted_by 兩欄對 authenticated 完全沒有 UPDATE grant（含 owner／作者本人）——作者不能還原 owner 軟刪的防線在 grant 層，不必依賴 RLS';
end;
$$;

rollback;

-- ===========================================================================
-- 5. CHECK 約束：三項量測全空應失敗；任一項為負值／零應失敗。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 三項全空
  begin
    perform public.upsert_growth_record(null, v_child, current_date, null, null, null, '什麼都沒量');
    raise exception 'FAIL：三項量測全空的成長紀錄竟然新增成功';
  exception when check_violation then
    null;  -- ok
  end;

  -- 負值
  begin
    perform public.upsert_growth_record(null, v_child, current_date, -5.0, null, null, null);
    raise exception 'FAIL：height_cm 為負值竟然新增成功';
  exception when check_violation then
    null;  -- ok
  end;

  begin
    perform public.upsert_growth_record(null, v_child, current_date, null, -1.0, null, null);
    raise exception 'FAIL：weight_kg 為負值竟然新增成功';
  exception when check_violation then
    null;  -- ok
  end;

  -- 零值（>0 嚴格要求，0 不算合法量測）
  begin
    perform public.upsert_growth_record(null, v_child, current_date, null, null, 0, null);
    raise exception 'FAIL：head_cm 為 0 竟然新增成功';
  exception when check_violation then
    null;  -- ok
  end;

  -- 正向對照：只填一項且為正值，成功
  perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null);

  reset role;
  raise notice 'ok：三項全空／負值／零值皆被 CHECK 擋下（23514）；只填一項正值成功（正向對照）';
end;
$$;

rollback;

-- ===========================================================================
-- 6. list_growth_records：排序（measured_on desc, id desc）、真正的 2 元組
--    keyset 分頁（p_before／p_before_id）、p_limit 收斂、半游標 LS022、
--    **同日多筆跨頁邊界**（merge-review R1 M1 訂正的邊界——見下方獨立區塊）。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_page1 date[];
  v_page2 date[];
  v_last public.growth_records;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 3 筆不同日期（由舊到新建立，故意跟預期輸出順序相反）
  perform public.upsert_growth_record(null, v_child, date '2026-01-01', 65.0, null, null, null);
  perform public.upsert_growth_record(null, v_child, date '2026-02-01', 68.0, null, null, null);
  perform public.upsert_growth_record(null, v_child, date '2026-03-01', 70.0, null, null, null);

  -- 第一頁 limit 2：應為 2026-03-01, 2026-02-01（measured_on desc）
  select array_agg(g.measured_on order by g.measured_on desc) into v_page1
    from public.list_growth_records(v_child, 2, null, null) g;
  if v_page1 <> array[date '2026-03-01', date '2026-02-01'] then
    raise exception 'FAIL：list_growth_records 第一頁順序不符，實際 %', v_page1;
  end if;

  -- 第二頁：游標取第一頁最後一列的 (measured_on, id)，應只剩 2026-01-01
  select g.* into v_last
    from public.list_growth_records(v_child, 2, null, null) g
   order by g.measured_on asc limit 1;
  select array_agg(g.measured_on order by g.measured_on desc) into v_page2
    from public.list_growth_records(v_child, 2, v_last.measured_on, v_last.id) g;
  if v_page2 <> array[date '2026-01-01'] then
    raise exception 'FAIL：list_growth_records 第二頁（游標取第一頁最後一列）不符，實際 %', v_page2;
  end if;

  -- p_limit 收斂：傳 0 應至少回 1 筆（clamp 到下限 1），不是回 0 筆
  if (select count(*) from public.list_growth_records(v_child, 0, null, null)) < 1 then
    raise exception 'FAIL：p_limit=0 時 list_growth_records 竟然回傳 0 列（應 clamp 到下限 1）';
  end if;

  -- 半游標：只給 p_before 不給 p_before_id（或反過來）一律 LS022
  begin
    perform public.list_growth_records(v_child, 2, date '2026-02-01', null);
    raise exception 'FAIL：只給 p_before 不給 p_before_id 竟然沒有出錯';
  exception when others then
    if sqlstate <> 'LS022' then
      raise exception 'FAIL：半游標應拿到 LS022，實際 %', sqlstate;
    end if;
  end;
  begin
    perform public.list_growth_records(v_child, 2, null, gen_random_uuid());
    raise exception 'FAIL：只給 p_before_id 不給 p_before 竟然沒有出錯';
  exception when others then
    if sqlstate <> 'LS022' then
      raise exception 'FAIL：半游標應拿到 LS022，實際 %', sqlstate;
    end if;
  end;

  reset role;
  raise notice 'ok：list_growth_records 排序與游標分頁正確，p_limit 下限 clamp 生效，半游標拿 LS022';
end;
$$;

rollback;

-- ===========================================================================
-- 6b.（merge-review R1 M1，major）同日多筆跨頁邊界：4 筆——D1 單獨一天、
--    D2a／D2b 同一天、D3 更早一天，`p_limit=2` 分頁必須合計走訪到全部 4 筆、
--    無重複、無遺漏——reviewer 用這個確切情境（4 筆／limit=2）實跑重現過 R1
--    版本（`measured_on < p_before` 單值游標）只走訪到 3 筆、漏掉頁尾同日的
--    另一筆。
--
-- Mutation 自證（開發期間手動驗證，已改回原狀）：把
-- `and (g.measured_on, g.id) < (p_before, p_before_id)` 暫時改回 R1 的
-- `and g.measured_on < p_before`（拿掉 id 這個游標維度）後重跑本區塊，斷言由
-- 綠轉紅（`FAIL：分頁走訪合計應為 4 筆，實際 3`，與 reviewer R1 review 實跑的
-- 現象逐字相符）；改回 `(measured_on, id) < (p_before, p_before_id)` 後重跑
-- 恢復綠。證明這個斷言真的在測 M1 修正本身，不是恆綠空案。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_d1 uuid;
  v_d2a uuid;
  v_d2b uuid;
  v_d3 uuid;
  v_page1 uuid[];
  v_last public.growth_records;
  v_page2 uuid[];
  v_all uuid[];
  v_distinct_count int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_d1  := (public.upsert_growth_record(null, v_child, date '2026-05-10', 70.0, null, null, 'D1')).id;
  v_d2a := (public.upsert_growth_record(null, v_child, date '2026-05-05', 71.0, null, null, 'D2a')).id;
  v_d2b := (public.upsert_growth_record(null, v_child, date '2026-05-05', 72.0, null, null, 'D2b')).id;
  v_d3  := (public.upsert_growth_record(null, v_child, date '2026-05-01', 73.0, null, null, 'D3')).id;

  -- page1：limit=2，游標為空
  select array_agg(g.id) into v_page1
    from public.list_growth_records(v_child, 2, null, null) g;
  if array_length(v_page1, 1) <> 2 then
    raise exception 'FAIL：page1 應為 2 筆，實際 %', array_length(v_page1, 1);
  end if;

  -- 取 page1 最後一列（measured_on 最早的那筆）當下一頁游標
  select g.* into v_last
    from public.list_growth_records(v_child, 2, null, null) g
   order by g.measured_on asc, g.id asc limit 1;

  -- page2：游標接續，limit 給大一點（100）確保能拿到剩下全部
  select array_agg(g.id) into v_page2
    from public.list_growth_records(v_child, 100, v_last.measured_on, v_last.id) g;

  select array_agg(distinct x) into v_all
    from unnest(v_page1 || coalesce(v_page2, array[]::uuid[])) as x;
  select array_length(v_all, 1) into v_distinct_count;

  if v_distinct_count <> 4 then
    raise exception 'FAIL：分頁走訪合計應為 4 筆，實際 %（page1=% page2=%）',
      v_distinct_count, v_page1, v_page2;
  end if;

  if array_length(v_page1, 1) + coalesce(array_length(v_page2, 1), 0) <> v_distinct_count then
    raise exception 'FAIL：分頁走訪出現重複（page1=% page2=% 但去重後只有 % 筆）',
      v_page1, v_page2, v_distinct_count;
  end if;

  if not (v_d1 = any(v_all) and v_d2a = any(v_all) and v_d2b = any(v_all) and v_d3 = any(v_all)) then
    raise exception 'FAIL：D1/D2a/D2b/D3 四筆沒有全部出現在分頁結果裡（實際 %）', v_all;
  end if;

  reset role;
  raise notice 'ok：同日多筆（D2a／D2b）跨頁邊界正確——4 筆全部走訪到、無重複（M1 修正）';
end;
$$;

rollback;

-- ===========================================================================
-- 7. upsert_growth_record：新增／更新分支的邊界情況——p_child_id 不存在（42501）、
--    p_id 不存在或非作者（42501）。
--
-- p_child_id 不存在時實際拿到的是 42501（RLS 違反），不是原本猜測的 23502
-- （not_null_violation）——本機 supabase db reset 實測：PostgreSQL 對 INSERT 先
-- 評估 RLS 的 WITH CHECK 才輪到 NOT NULL 約束，family_id 解析為 NULL 時
-- `NULL in (select private.contributor_family_ids())` 求值為 NULL（非 TRUE），
-- WITH CHECK 判定不通過，冒出的是標準 RLS 違反訊息，不會走到 NOT NULL 檢查那一關
-- （見 migration 檔頭第 6 段 upsert_growth_record 說明的訂正記錄）。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- p_child_id 不存在：family_id 解析為 NULL，撞 RLS 的 WITH CHECK（見上方說明）
  begin
    perform public.upsert_growth_record(null, gen_random_uuid(), current_date, 70.0, null, null, null);
    raise exception 'FAIL：p_child_id 不存在竟然新增成功';
  exception when insufficient_privilege then
    null;  -- ok（42501）
  end;

  -- p_id 不存在：更新分支 42501
  begin
    perform public.upsert_growth_record(gen_random_uuid(), v_child, current_date, 70.0, null, null, null);
    raise exception 'FAIL：p_id 不存在竟然更新成功';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：p_id 不存在應拿到 42501，實際 %', sqlstate;
    end if;
  end;

  reset role;
  raise notice 'ok：p_child_id 不存在拿 42501（RLS 違反，非 23502）；p_id 不存在拿 42501';
end;
$$;

rollback;

-- ===========================================================================
-- 8. delete_growth_record：作者本人可軟刪自己的；owner 可軟刪任何一筆；非作者
--    非 owner 不行；owner 對已被作者自刪的紀錄再次呼叫，deleted_by 升級成 owner
--    （LS-57 既有規則，共用 trigger 帶來的行為）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id1 uuid;
  v_id2 uuid;
  v_deleted_at timestamptz;
  v_deleted_by uuid;
begin
  -- 作者本人可軟刪自己的
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null)).id into v_id1;
  perform public.delete_growth_record(v_id1);
  reset role;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by
    from public.growth_records where id = v_id1;
  if v_deleted_at is null or v_deleted_by <> v_member then
    raise exception 'FAIL：作者軟刪自己的紀錄後 deleted_at/deleted_by 沒有正確寫入（deleted_at=%，deleted_by=%）',
      v_deleted_at, v_deleted_by;
  end if;
  raise notice 'ok：作者本人可軟刪自己的成長紀錄，deleted_at/deleted_by 正確寫入';

  -- 同一交易內 now() 是常數（transaction_timestamp 語意，同
  -- 88_deletion_attribution.sql 檔頭的既有說明）——下面「owner 對已被作者自刪的
  -- 紀錄再次呼叫」那段需要 owner 這次呼叫的 now() 跟這裡的 deleted_at 不同，
  -- 才踩得到 enforce_deletion_attribution() trigger 真正的 transition 邏輯（否則
  -- `new.deleted_at is not distinct from old.deleted_at` 短路會讓 trigger 整段
  -- 跳過，深層驗不到升級行為）。用 postgres 身分把 deleted_at 直接回填成一小時前
  -- （bypass RLS／grant，且不透過 delete_growth_record，因為那支只會寫 now()）。
  update public.growth_records set deleted_at = now() - interval '1 hour' where id = v_id1;

  -- 非作者、非 owner 不行（viewer／非本家庭成員）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 71.0, null, null, null)).id into v_id2;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.delete_growth_record(v_id2);
    raise exception 'FAIL：viewer 竟然可以軟刪別人的成長紀錄';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：viewer 軟刪應拿到 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.delete_growth_record(v_id2);
    raise exception 'FAIL：非本家庭成員竟然可以軟刪這筆成長紀錄';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：非本家庭成員軟刪應拿到 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：非作者且非 owner（viewer／非本家庭成員）皆無法軟刪（42501）';

  -- owner 可軟刪任何一筆（不限自己作者的）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_growth_record(v_id2);
  reset role;

  select deleted_at, deleted_by into v_deleted_at, v_deleted_by
    from public.growth_records where id = v_id2;
  if v_deleted_at is null or v_deleted_by <> v_owner then
    raise exception 'FAIL：owner 軟刪別人的紀錄後 deleted_at/deleted_by 沒有正確寫入（deleted_at=%，deleted_by=%）',
      v_deleted_at, v_deleted_by;
  end if;
  raise notice 'ok：owner 可軟刪任何一筆成長紀錄（不限自己作者的），deleted_by 正確記為 owner';

  -- owner 對已被作者自刪的紀錄再次呼叫：deleted_by 升級成 owner（LS-57 既有規則，
  -- 共用 trigger 帶來的行為——v_id1 前面已由作者 member 軟刪過一次）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_growth_record(v_id1);
  reset role;

  select deleted_by into v_deleted_by from public.growth_records where id = v_id1;
  if v_deleted_by <> v_owner then
    raise exception 'FAIL：owner 對已被作者自刪的紀錄再次呼叫 delete_growth_record，deleted_by 應升級成 owner（LS-57），實際 %', v_deleted_by;
  end if;
  raise notice 'ok：owner 對已被作者自刪的紀錄再次呼叫，deleted_by 升級成 owner（LS-57 共用 trigger 行為）';
end;
$$;

rollback;

-- ===========================================================================
-- 8b.（merge-review R1 m1）owner 已軟刪的紀錄，作者跨交易再呼叫
--    delete_growth_record 拿 LS027（既有碼，API.md 已補登記）——delete_growth_
--    record 本身的授權檢查（owner 或「作者且仍是成員」）會放行作者，但底下的
--    UPDATE 觸發共用 trigger 的還原鎖，擋下「不是自己軟刪的」再次觸碰。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_id uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null)).id into v_id;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_growth_record(v_id);
  reset role;

  -- 跨交易：把 deleted_at 回填成更早的時間戳（同 §8 的既有手法），確保作者這次
  -- 呼叫的 now() 與 owner 剛剛軟刪時不同，才踩得到 trigger 真正的還原鎖分支。
  update public.growth_records set deleted_at = now() - interval '1 hour' where id = v_id;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.delete_growth_record(v_id);
    raise exception 'FAIL：作者對 owner 已軟刪的紀錄再次呼叫 delete_growth_record 竟然沒有出錯';
  exception when others then
    if sqlstate <> 'LS027' then
      raise exception 'FAIL：作者對 owner 已軟刪的紀錄再次呼叫應拿到 LS027，實際 %', sqlstate;
    end if;
  end;
  reset role;

  -- deleted_by 仍是 owner，沒有被這次失敗的呼叫動到
  if (select deleted_by from public.growth_records where id = v_id) <> v_owner then
    raise exception 'FAIL：LS027 擋下之後，deleted_by 竟然不再是 owner';
  end if;
  raise notice 'ok：owner 已軟刪的紀錄，作者跨交易再呼叫 delete_growth_record 拿 LS027（既有碼）';
end;
$$;

rollback;

-- ===========================================================================
-- 8c.（merge-review R1 m2）已軟刪的孩子不能再被指定為新的成長紀錄——重用 LS-121
--    的共用函式 private.enforce_child_not_deleted()，拋既有碼 LS044。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_child := public.create_child(v_family, 'LS-255 m2 已軟刪孩子', date '2025-01-01', null);
  perform public.set_child_deleted(v_child, true);

  begin
    perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null);
    raise exception 'FAIL：已軟刪的孩子竟然還能被新增成長紀錄';
  exception when others then
    if sqlstate <> 'LS044' then
      raise exception 'FAIL：已軟刪的孩子新增成長紀錄應拿到 LS044，實際 %', sqlstate;
    end if;
  end;

  -- 正向對照：active 孩子完全不受影響
  perform public.set_child_deleted(v_child, false);
  perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, null);

  reset role;
  raise notice 'ok：已軟刪的孩子新增成長紀錄拿 LS044；還原後（active）新增不受影響（正向對照）';
end;
$$;

rollback;

-- ===========================================================================
-- 8d.（merge-review R1 m3）note 長度上限：超過 2000 字拋 23514；剛好 2000 字
--    成功（邊界含）。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, repeat('x', 2001));
    raise exception 'FAIL：note 2001 字竟然新增成功';
  exception when check_violation then
    null;  -- ok
  end;

  perform public.upsert_growth_record(null, v_child, current_date, 70.0, null, null, repeat('x', 2000));

  reset role;
  raise notice 'ok：note 超過 2000 字拋 23514；剛好 2000 字成功（邊界含）';
end;
$$;

rollback;

-- ===========================================================================
-- 8e.（R1 informational i2）growth_records_deletion_guard／growth_records_
--    not_suspended 兩支共用 guard trigger 掛載正確——結構性回歸保護：日後若這兩支
--    trigger 被誤刪／改錯函式，這裡會直接抓到，不必等到帳號刪除過渡期／停權
--    情境才發現。行為本身（LS051／LS052／LS053 各自的判斷邏輯）已由
--    private.enforce_account_not_deletion_requested()／enforce_not_suspended()
--    共用函式自己的既有測試（92_delete_account_edge_guard.sql／105_suspension_
--    and_registrations.sql）逐路徑覆蓋，這裡不重複跑一次那些情境，只釘住
--    「growth_records 有沒有掛上」這件事本身。
-- ===========================================================================
begin;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
   where t.tgrelid = 'public.growth_records'::regclass
     and t.tgname = 'growth_records_deletion_guard';
  if v_def is null or v_def !~ 'enforce_account_not_deletion_requested' or v_def !~ 'INSERT' then
    raise exception 'FAIL：growth_records_deletion_guard 沒有正確掛上 private.enforce_account_not_deletion_requested()（BEFORE INSERT），實際：%', v_def;
  end if;

  select pg_get_triggerdef(t.oid) into v_def
    from pg_trigger t
   where t.tgrelid = 'public.growth_records'::regclass
     and t.tgname = 'growth_records_not_suspended';
  if v_def is null or v_def !~ 'enforce_not_suspended'
     or v_def !~ 'INSERT' or v_def !~ 'UPDATE' or v_def !~ 'DELETE' then
    raise exception 'FAIL：growth_records_not_suspended 沒有正確掛上 private.enforce_not_suspended()（BEFORE INSERT/UPDATE/DELETE），實際：%', v_def;
  end if;

  raise notice 'ok：growth_records_deletion_guard（LS051）／growth_records_not_suspended（LS052/LS053）兩支共用 guard trigger 皆正確掛載';
end;
$$;

rollback;

-- ===========================================================================
-- 9. EXPLAIN 證據：growth_records_child_measured_idx 部分索引被實際選用。
--    目標孩子 100 筆（80 存活＋20 已刪雜訊）＋另一個孩子 5000 筆背景雜訊（bulk
--    直接 INSERT，比照 00_fixtures.sql 的 private.ls204_seed_media_perf_noise()
--    既有手法）——資料量小到全表只有幾頁時，規劃器選 Seq Scan 完全正確（本檔
--    開發期間第一版只有 100 筆總量，實測 Seq Scan 每次勝出，buffers 一樣很低，
--    但那測不出「部分索引真的被選中」這件事，只測得出「資料量小、怎麼查都快」；
--    加上背景雜訊撐大全表之後才有意義比較 Index Scan vs. Seq Scan 的成本）。沿用
--    00_fixtures.sql 既有的 A 家／owner a1；VACUUM 不能在交易區塊內執行，故放在
--    begin; 之前。
-- ===========================================================================

vacuum (analyze) public.growth_records;

begin;

select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  v_child uuid;
  v_noise_child uuid;
  v_id uuid;
begin
  v_child := public.create_child(
    'fa000000-0000-4000-8000-000000000001'::uuid, 'LS-255 EXPLAIN 孩子', date '2025-01-01', null
  );
  v_noise_child := public.create_child(
    'fa000000-0000-4000-8000-000000000001'::uuid, 'LS-255 EXPLAIN 雜訊孩子', date '2025-01-01', null
  );

  perform public.upsert_growth_record(null, v_child, current_date - i, 60 + i * 0.1, null, null, null)
    from generate_series(1, 100) i;

  -- 20 筆已刪雜訊：拿最舊的 20 筆軟刪（i 最大＝measured_on 最早），partial index
  -- 應該完全不會走訪這些死列（主查詢是 measured_on desc 取前段，落在存活的那 80 筆）。
  for v_id in
    select g.id from public.growth_records g where g.child_id = v_child
     order by g.measured_on asc limit 20
  loop
    perform public.delete_growth_record(v_id);
  end loop;

  perform set_config('ls255.explain_child_id', v_child::text, true);
  perform set_config('ls255.explain_noise_child_id', v_noise_child::text, true);
end;
$$;

-- 5000 筆背景雜訊：另一個孩子的成長紀錄，直接 bulk INSERT（bypass RPC，比照
-- 00_fixtures.sql 既有的 private.ls204_seed_media_perf_noise() 手法——純粹是為了
-- 撐大全表，不需要逐筆走 RLS／授權路徑）。`created_at` 不在 authenticated 的欄位
-- 級 INSERT grant 內（見 migration 第 3 段），這裡換回 postgres 身分執行，繞過
-- 欄位級 grant——純測試 fixture 撐資料量，不是要驗證這個寫入路徑本身的授權。
reset role;
insert into public.growth_records (family_id, child_id, author_id, measured_on, height_cm, created_at)
select 'fa000000-0000-4000-8000-000000000001'::uuid,
       current_setting('ls255.explain_noise_child_id')::uuid,
       'a0000000-0000-4000-8000-000000000001'::uuid,
       current_date - (i % 3650), 70.0, now() - (i * interval '1 minute')
  from generate_series(1, 5000) i;

-- ANALYZE 需要表擁有者權限，authenticated 沒有——已經是 postgres 身分，直接跑。
-- 下面換回 authenticated 且重新帶 JWT claims 是必要的：growth_records_select 的
-- `deleted_at is null` 濾除是 RLS policy 的一部分，只有以 authenticated 身分、
-- 帶著合法 JWT 呼叫 list_growth_records 才會被注入這個條件，讓規劃器有機會選中
-- growth_records_child_measured_idx 這個部分索引（postgres 身分繞過 RLS，
-- 少了這個條件，規劃器反而不會選這個部分索引，量到的就不是這裡要驗的東西）。
reset role;
analyze public.growth_records;

select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  v_child uuid := current_setting('ls255.explain_child_id')::uuid;
  v_line text;
  v_plan text := '';
  v_hit bigint;
  v_read bigint;
  v_buffers bigint;
  -- 目標孩子 100 筆（80 存活＋20 已刪）＋另一個孩子 5000 筆背景雜訊，共約 5100 列
  -- 全表，走 growth_records_child_measured_idx 部分索引取目標孩子前 20 筆：預期
  -- 是單次 Index Scan（不掃到雜訊），buffers 應為個位數到低雙位數（比照 112_ 的
  -- 抓法，門檻給充足餘裕，這個資料量級離門檻應該還有一大截）。
  c_buffer_budget constant bigint := 60;
begin
  perform * from public.list_growth_records(v_child, 20, null, null);  -- 暖機（同 112_ 既有慣例：session 第一次呼叫 plpgsql 函式有一次性 parse/plan cache 成本）

  for v_line in execute
    'explain (analyze, verbose, buffers) select * from public.list_growth_records(' ||
    quote_literal(v_child::text) || '::uuid, 20, null, null)'
  loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  select coalesce(sum((x[1])::bigint), 0) into v_hit
    from regexp_matches(v_plan, 'shared hit=([0-9]+)', 'g') as x;
  select coalesce(sum((x[1])::bigint), 0) into v_read
    from regexp_matches(v_plan, E'read=([0-9]+)', 'g') as x;
  v_buffers := v_hit + v_read;

  if v_buffers > c_buffer_budget then
    raise exception E'FAIL 效能：list_growth_records buffers=%（hit=% read=%，門檻 %）\n%',
      v_buffers, v_hit, v_read, c_buffer_budget, v_plan;
  end if;

  raise notice 'ok 效能：list_growth_records（目標孩子 100 筆＋另一孩子 5000 筆背景雜訊，共約 5100 列全表）buffers=%（hit=% read=%，門檻 ≤%）',
    v_buffers, v_hit, v_read, c_buffer_budget;
end;
$$;

-- 上面對「呼叫 RPC」量到的 buffers 已經是正確的效能證據（EXPLAIN 對 PL/pgSQL
-- 函式呼叫本來就只會印出不透明的 Function Scan 節點，看不到函式內部選了哪個
-- index——跟 112_comment_count.sql／get_family_timeline 的既有慣例一樣，函式呼叫
-- 這層只驗 buffers，不驗 index 名稱）。要直接看到「選了哪個 index」，另外對函式
-- 內部第一個分支（p_before is null）逐字一致的查詢文字單獨下一次 EXPLAIN（同
-- 20260824010000_diaries_write_path_and_timeline.sql 檔頭引用的 50_ 既有手法：
-- 對 RPC 呼叫與函式內部查詢文字各驗一次，兩者若之後任一邊改了查詢文字忘記同步
-- 改另一邊，這裡會用得到跟部署不一致的查詢，及早瞡動 gap）。
do $$
declare
  v_child uuid := current_setting('ls255.explain_child_id')::uuid;
  v_line text;
  v_plan text := '';
begin
  for v_line in execute
    'explain (analyze, verbose, buffers) select g.* from public.growth_records g' ||
    ' where g.child_id = ' || quote_literal(v_child::text) || '::uuid' ||
    ' order by g.measured_on desc, g.id desc limit 20'
  loop
    v_plan := v_plan || v_line || E'\n';
  end loop;

  if v_plan !~ 'growth_records_child_measured_idx' then
    raise exception E'FAIL 效能：函式內部（p_before is null 分支）逐字一致的查詢文字沒有選用 growth_records_child_measured_idx 部分索引\n%', v_plan;
  end if;

  raise notice 'ok 效能：函式內部查詢文字（p_before is null 分支）確認選用 growth_records_child_measured_idx 部分索引';
end;
$$;

\echo ''
\echo '=== EXPLAIN 證據：list_growth_records 100 筆同孩子（80 存活＋20 已刪）走部分索引（LS-255）==='
explain (analyze, verbose, buffers)
select * from public.list_growth_records(current_setting('ls255.explain_child_id')::uuid, 20, null, null);

\echo ''
\echo '=== EXPLAIN 證據：函式內部查詢文字（p_before is null 分支）逐字一致（LS-255）==='
explain (analyze, verbose, buffers)
select g.* from public.growth_records g
 where g.child_id = current_setting('ls255.explain_child_id')::uuid
 order by g.measured_on desc, g.id desc
 limit 20;

reset role;
rollback;
