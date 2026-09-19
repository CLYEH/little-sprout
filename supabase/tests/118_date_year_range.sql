-- LS-336（源自 LS-331 merge-review R1 X1）—— 四個 `date` 欄位的年份範圍 CHECK 自測：
-- `children.birthday`／`diaries.entry_date`／`growth_records.measured_on`／
-- `child_food_records.first_tried_on`，每欄各驗：
--   1. 極端壞值（LS-331 實際見過的形狀：`0115-…`／`3937-…`）被擋（23514）。
--   2. 邊界外一天（`1899-12-31`／`2200-01-02`）被擋（23514）。
--   3. 邊界本身（`1900-01-01`／`2200-01-01`）允許，且讀回值不失真。
--   4. 至少一條走 RPC 的「更新」路徑（不只新增）一樣被擋。
-- 沿用 00_fixtures.sql 的 A 家：owner=a1、child=2a000000-…-1（小芽）。每個編號段
-- 各自 begin;/rollback; 包起來（同 113_growth_records.sql／115_media_taken_at.sql／
-- 117_food_encyclopedia.sql 既有慣例）。
\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. children.birthday（children_birthday_year_range）
-- ===========================================================================
begin;
do $$
declare
  v_owner constant uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fa000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_birthday date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ---- 極端壞值（LS-331 實際見過的形狀）----
  begin
    perform public.create_child(v_family, '測試-民國誤植', date '0115-09-19', null);
    raise exception 'FAIL：birthday=0115-09-19 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：birthday=0115-09-19 被 children_birthday_year_range 擋下（23514）';
  end;

  begin
    perform public.create_child(v_family, '測試-年份爆表', date '3937-09-04', null);
    raise exception 'FAIL：birthday=3937-09-04 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：birthday=3937-09-04 被 children_birthday_year_range 擋下（23514）';
  end;

  -- ---- 邊界外一天 ----
  begin
    perform public.create_child(v_family, '測試-下限外一天', date '1899-12-31', null);
    raise exception 'FAIL：birthday=1899-12-31 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：birthday=1899-12-31（下限外一天）被擋下（23514）';
  end;

  begin
    perform public.create_child(v_family, '測試-上限外一天', date '2200-01-02', null);
    raise exception 'FAIL：birthday=2200-01-02 竟然新增成功（mutation：把上限改成 2200-01-02 或拿掉 CHECK 這裡會不紅）';
  exception when check_violation then
    raise notice 'ok：birthday=2200-01-02（上限外一天）被擋下（23514）';
  end;

  -- ---- 邊界本身：允許，且讀回值不失真 ----
  v_id := public.create_child(v_family, '測試-下限本身', date '1900-01-01', null);
  select c.birthday into v_birthday from public.children c where c.id = v_id;
  if v_birthday is distinct from date '1900-01-01' then
    raise exception 'FAIL：birthday 下限 1900-01-01 讀回值不符，實際 %', v_birthday;
  end if;
  raise notice 'ok：birthday=1900-01-01（下限本身）新增成功，讀回值不失真';

  v_id := public.create_child(v_family, '測試-上限本身', date '2200-01-01', null);
  select c.birthday into v_birthday from public.children c where c.id = v_id;
  if v_birthday is distinct from date '2200-01-01' then
    raise exception 'FAIL：birthday 上限 2200-01-01 讀回值不符，實際 %', v_birthday;
  end if;
  raise notice 'ok：birthday=2200-01-01（上限本身）新增成功，讀回值不失真';

  -- ---- 更新路徑（update_child）一樣受 CHECK 約束，不只新增 ----
  begin
    perform public.update_child(v_id, '測試-上限本身', date '0008-01-01', null);
    raise exception 'FAIL：update_child 把 birthday 改成 0008-01-01 竟然成功';
  exception when check_violation then
    raise notice 'ok：update_child 的 birthday=0008-01-01 一樣被擋下（CHECK 對 INSERT／UPDATE 皆生效）';
  end;

  reset role;
end;
$$;
rollback;

-- ===========================================================================
-- 2. diaries.entry_date（diaries_entry_date_year_range）
-- ===========================================================================
begin;
do $$
declare
  v_owner constant uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family constant uuid := 'fa000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_entry_date date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '0115-09-19');
    raise exception 'FAIL：entry_date=0115-09-19 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：entry_date=0115-09-19 被 diaries_entry_date_year_range 擋下（23514）';
  end;

  begin
    perform public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '3937-09-04');
    raise exception 'FAIL：entry_date=3937-09-04 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：entry_date=3937-09-04 被 diaries_entry_date_year_range 擋下（23514）';
  end;

  begin
    perform public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '1899-12-31');
    raise exception 'FAIL：entry_date=1899-12-31 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：entry_date=1899-12-31（下限外一天）被擋下（23514）';
  end;

  begin
    perform public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '2200-01-02');
    raise exception 'FAIL：entry_date=2200-01-02 竟然新增成功（mutation：拿掉 CHECK 這裡會不紅）';
  exception when check_violation then
    raise notice 'ok：entry_date=2200-01-02（上限外一天）被擋下（23514）';
  end;

  v_id := public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '1900-01-01');
  select d.entry_date into v_entry_date from public.diaries d where d.id = v_id;
  if v_entry_date is distinct from date '1900-01-01' then
    raise exception 'FAIL：entry_date 下限 1900-01-01 讀回值不符，實際 %', v_entry_date;
  end if;
  raise notice 'ok：entry_date=1900-01-01（下限本身）新增成功，讀回值不失真';

  v_id := public.create_diary_entry(v_family, array[]::uuid[], '測試日記', date '2200-01-01');
  select d.entry_date into v_entry_date from public.diaries d where d.id = v_id;
  if v_entry_date is distinct from date '2200-01-01' then
    raise exception 'FAIL：entry_date 上限 2200-01-01 讀回值不符，實際 %', v_entry_date;
  end if;
  raise notice 'ok：entry_date=2200-01-01（上限本身）新增成功，讀回值不失真';

  -- ---- 更新路徑（update_diary_entry）一樣受 CHECK 約束 ----
  begin
    perform public.update_diary_entry(v_id, '測試日記（改）', date '0008-01-01', array[]::uuid[]);
    raise exception 'FAIL：update_diary_entry 把 entry_date 改成 0008-01-01 竟然成功';
  exception when check_violation then
    raise notice 'ok：update_diary_entry 的 entry_date=0008-01-01 一樣被擋下';
  end;

  reset role;
end;
$$;
rollback;

-- ===========================================================================
-- 3. growth_records.measured_on（growth_records_measured_on_year_range）
-- ===========================================================================
begin;
do $$
declare
  v_owner constant uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child constant uuid := '2a000000-0000-4000-8000-000000000001';
  v_row public.growth_records%rowtype;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.upsert_growth_record(null, v_child, date '0115-09-19', 70.0, null, null, null);
    raise exception 'FAIL：measured_on=0115-09-19 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：measured_on=0115-09-19 被 growth_records_measured_on_year_range 擋下（23514）';
  end;

  begin
    perform public.upsert_growth_record(null, v_child, date '3937-09-04', 70.0, null, null, null);
    raise exception 'FAIL：measured_on=3937-09-04 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：measured_on=3937-09-04 被 growth_records_measured_on_year_range 擋下（23514）';
  end;

  begin
    perform public.upsert_growth_record(null, v_child, date '1899-12-31', 70.0, null, null, null);
    raise exception 'FAIL：measured_on=1899-12-31 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：measured_on=1899-12-31（下限外一天）被擋下（23514）';
  end;

  begin
    perform public.upsert_growth_record(null, v_child, date '2200-01-02', 70.0, null, null, null);
    raise exception 'FAIL：measured_on=2200-01-02 竟然新增成功（mutation：拿掉 CHECK 這裡會不紅）';
  exception when check_violation then
    raise notice 'ok：measured_on=2200-01-02（上限外一天）被擋下（23514）';
  end;

  v_row := public.upsert_growth_record(null, v_child, date '1900-01-01', 70.0, null, null, null);
  if v_row.measured_on is distinct from date '1900-01-01' then
    raise exception 'FAIL：measured_on 下限 1900-01-01 讀回值不符，實際 %', v_row.measured_on;
  end if;
  raise notice 'ok：measured_on=1900-01-01（下限本身）新增成功，讀回值不失真';

  v_row := public.upsert_growth_record(null, v_child, date '2200-01-01', 71.0, null, null, null);
  if v_row.measured_on is distinct from date '2200-01-01' then
    raise exception 'FAIL：measured_on 上限 2200-01-01 讀回值不符，實際 %', v_row.measured_on;
  end if;
  raise notice 'ok：measured_on=2200-01-01（上限本身）新增成功，讀回值不失真';

  -- ---- 更新路徑（upsert_growth_record 帶 p_id）一樣受 CHECK 約束 ----
  begin
    perform public.upsert_growth_record(v_row.id, v_child, date '0008-01-01', 71.0, null, null, null);
    raise exception 'FAIL：upsert_growth_record 更新分支把 measured_on 改成 0008-01-01 竟然成功';
  exception when check_violation then
    raise notice 'ok：upsert_growth_record 更新分支的 measured_on=0008-01-01 一樣被擋下';
  end;

  reset role;
end;
$$;
rollback;

-- ===========================================================================
-- 4. child_food_records.first_tried_on（child_food_records_first_tried_on_year_range）
-- ===========================================================================
begin;
do $$
declare
  v_owner constant uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child constant uuid := '2a000000-0000-4000-8000-000000000001';
  v_row public.child_food_records%rowtype;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.upsert_child_food_record(v_child, 'banana', date '0115-09-19', null, null, null);
    raise exception 'FAIL：first_tried_on=0115-09-19 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：first_tried_on=0115-09-19 被 child_food_records_first_tried_on_year_range 擋下（23514）';
  end;

  begin
    perform public.upsert_child_food_record(v_child, 'banana', date '3937-09-04', null, null, null);
    raise exception 'FAIL：first_tried_on=3937-09-04 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：first_tried_on=3937-09-04 被 child_food_records_first_tried_on_year_range 擋下（23514）';
  end;

  begin
    perform public.upsert_child_food_record(v_child, 'banana', date '1899-12-31', null, null, null);
    raise exception 'FAIL：first_tried_on=1899-12-31 竟然新增成功';
  exception when check_violation then
    raise notice 'ok：first_tried_on=1899-12-31（下限外一天）被擋下（23514）';
  end;

  begin
    perform public.upsert_child_food_record(v_child, 'banana', date '2200-01-02', null, null, null);
    raise exception 'FAIL：first_tried_on=2200-01-02 竟然新增成功（mutation：拿掉 CHECK 這裡會不紅）';
  exception when check_violation then
    raise notice 'ok：first_tried_on=2200-01-02（上限外一天）被擋下（23514）';
  end;

  -- 上面四次全部撞 CHECK 失敗、沒有留下任何列，v_child 對 'banana' 這個
  -- food_id 仍是「未嘗試」——下面兩個邊界本身的成功案例才是本段唯一真正落地
  -- 的列，'banana'／'apple' 兩個不同 food_id 避免撞
  -- (child_id, food_id) where deleted_at is null 的 partial unique index。
  v_row := public.upsert_child_food_record(v_child, 'banana', date '1900-01-01', null, null, null);
  if v_row.first_tried_on is distinct from date '1900-01-01' then
    raise exception 'FAIL：first_tried_on 下限 1900-01-01 讀回值不符，實際 %', v_row.first_tried_on;
  end if;
  raise notice 'ok：first_tried_on=1900-01-01（下限本身）新增成功，讀回值不失真';

  v_row := public.upsert_child_food_record(v_child, 'apple', date '2200-01-01', null, null, null);
  if v_row.first_tried_on is distinct from date '2200-01-01' then
    raise exception 'FAIL：first_tried_on 上限 2200-01-01 讀回值不符，實際 %', v_row.first_tried_on;
  end if;
  raise notice 'ok：first_tried_on=2200-01-01（上限本身）新增成功，讀回值不失真';

  -- ---- 更新路徑：INSERT ... ON CONFLICT DO UPDATE（同 child_id/food_id='banana'
  -- 再呼叫一次）一樣受 CHECK 約束，不只純新增 ----
  begin
    perform public.upsert_child_food_record(v_child, 'banana', date '0008-01-01', null, null, null);
    raise exception 'FAIL：upsert_child_food_record 撞 ON CONFLICT DO UPDATE 分支把 first_tried_on 改成 0008-01-01 竟然成功';
  exception when check_violation then
    raise notice 'ok：upsert_child_food_record 的 ON CONFLICT DO UPDATE 分支 first_tried_on=0008-01-01 一樣被擋下';
  end;

  reset role;
end;
$$;
rollback;
