-- LS-325（LS-310 F5b 後端先行）—— 飲食圖鑑驗收：food_catalog／child_food_records／
-- RLS／三支 RPC／時間軸 food_first。
--
-- 對應 supabase/migrations/20260918205141_food_encyclopedia.sql 的每一項決定。角色
-- 矩陣沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3、
-- child=2a000000-0000-4000-8000-000000000001（小芽）；非本家庭成員用 B 家 owner
-- （b1）代表。§1（food_catalog↔CSV 一致性）由 run.sh 在跑本檔之前先用
-- scripts/ops/food-catalog-sql.py 動態產生（見 run.sh 主迴圈），本檔從 §2 開始。
--
-- 每個編號段各自用 begin;/rollback; 包起來（同 85_diaries_timeline.sql／
-- 113_growth_records.sql 的既有慣例），段內對資料的任何變更 rollback 會自動還原。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 2. food_catalog：三角色（含 viewer）皆可 SELECT；直接寫入被擋（無任何 grant）。
-- ===========================================================================
begin;

do $$
declare
  v_role uuid;
  v_n int;
begin
  foreach v_role in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003'   -- viewer
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_role, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_n from public.food_catalog;
    if v_n <> 122 then
      raise exception 'FAIL：% 讀 food_catalog 應看到 122 列，實際 %', v_role, v_n;
    end if;
    reset role;
  end loop;
  raise notice 'ok：owner／member／viewer 皆可讀到全部 122 列 food_catalog';
end;
$$;

do $$
begin
  if has_any_column_privilege('authenticated', 'public.food_catalog', 'insert')
     or has_any_column_privilege('authenticated', 'public.food_catalog', 'update')
     or has_table_privilege('authenticated', 'public.food_catalog', 'delete') then
    raise exception 'FAIL：authenticated 對 food_catalog 仍有寫入授權（表級或欄位級）';
  end if;
  if not has_table_privilege('authenticated', 'public.food_catalog', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 food_catalog 的 SELECT grant';
  end if;
  raise notice 'ok：food_catalog 授權對帳——INSERT/UPDATE/DELETE 無任何形態的 grant，SELECT 保留';
end;
$$;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.food_catalog (id, name_zh, category, sort_order) values ('x', 'x', 'grain_root', 999);
    raise exception 'FAIL：owner 竟然可以直接 INSERT food_catalog（唯讀目錄形同虛設）';
  exception when insufficient_privilege then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：即使是 owner，直接 INSERT food_catalog 也被擋下（42501）';
end;
$$;

rollback;

-- ===========================================================================
-- 3. child_food_records RLS：讀（家庭成員皆可，僅未刪列）／新增（owner／member，
--    viewer 不行，author_id 必須是自己）／更新內容（僅原作者本人）。
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
  v_id := (public.upsert_child_food_record(v_child, 'banana', current_date, null, '第一次吃香蕉', 'liked')).id;
  reset role;

  foreach v_role in array array[v_owner, v_member, v_viewer] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_role, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_count from public.child_food_records where id = v_id;
    if v_count <> 1 then
      raise exception 'FAIL：% 呼叫讀取應看到 1 列，實際 %', v_role, v_count;
    end if;
    reset role;
  end loop;
  raise notice 'ok：owner／member／viewer 皆可讀到同家庭未刪的飲食紀錄';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_count from public.child_food_records where id = v_id;
  if v_count <> 0 then
    raise exception 'FAIL：非本家庭成員（B 家 owner）竟然讀得到 A 家的飲食紀錄';
  end if;
  reset role;
  raise notice 'ok：非本家庭成員讀不到';

  -- viewer 不能新增
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_child_food_record(v_child, 'apple', current_date, null, null, null);
    raise exception 'FAIL：viewer 竟然可以新增飲食紀錄';
  exception when insufficient_privilege then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：viewer 無法新增飲食紀錄（42501）';

  -- 直接 INSERT 指定 author_id 為別人一律被擋
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.child_food_records (family_id, child_id, food_id, author_id, first_tried_on)
    values ('fa000000-0000-4000-8000-000000000001', v_child, 'apple', v_member, current_date);
    raise exception 'FAIL：owner 竟然可以直接 INSERT 把 author_id 指定成別人';
  exception when insufficient_privilege then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：直接 INSERT 指定 author_id 為別人被 WITH CHECK 擋下（42501）';

  -- mutation 自證（LS-209/LS-211）：growth_records §1 的既有寫法——這裡改用同一個
  -- 手法驗證「owner 不能直接編輯別人內容」這句斷言真的在測 RLS，不是恆綠空案。
  -- 開發期間手動把 child_food_records_update 暫時改成 using(true) with check(true)
  -- 重跑本檔，下面這段「owner 不能編輯別人內容」會由綠轉紅（FAIL：owner 竟然可以
  -- 直接編輯 member 的飲食紀錄內容）；改回原本定義後恢復全綠。證據見 PR handoff。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'apple', current_date, null, 'member 記的', 'liked');
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.child_food_records set note = 'owner 竄改' where child_id = v_child and food_id = 'apple';
  select count(*) into v_count from public.child_food_records
   where child_id = v_child and food_id = 'apple' and note = 'owner 竄改';
  if v_count <> 0 then
    raise exception 'FAIL：owner 竟然可以直接編輯 member 的飲食紀錄內容';
  end if;
  reset role;
  raise notice 'ok：owner 對別人的飲食紀錄直接 .update() 內容欄位是靜默 0 列（同 growth_records 既有形狀），不是 42501';
end;
$$;

rollback;

-- ===========================================================================
-- 4. LS044：p_child_id 指向已軟刪的孩子，新增分支被擋。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_deleted_child uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_deleted_child := public.create_child(v_family, '已軟刪測試孩子', date '2024-01-01', null);
  perform public.set_child_deleted(v_deleted_child, true);

  begin
    perform public.upsert_child_food_record(v_deleted_child, 'banana', current_date, null, null, null);
    raise exception 'FAIL：指向已軟刪的孩子竟然設定成功了';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：p_child_id 指向已軟刪的孩子，upsert_child_food_record 正確拿到 LS044';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 跨家庭 media：p_media_id 指向別家的照片，23503。
-- ===========================================================================
begin;

do $$
declare
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_other_family_media uuid := '3b000000-0000-4000-8000-000000000001';  -- B 家的照片
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_child_food_record(v_child, 'banana', current_date, v_other_family_media, null, null);
    raise exception 'FAIL：media_id 指向別家的照片竟然設定成功了';
  exception when foreign_key_violation then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：media_id 指向別家的照片被複合外鍵擋下（23503）';
end;
$$;

rollback;

-- ===========================================================================
-- 6. upsert_child_food_record 自然鍵語意：新增／同作者轉更新／非作者明確錯誤／
--    軟刪後可再新增。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_row public.child_food_records%rowtype;
  v_id1 uuid;
  v_n int;
begin
  -- (a) 新增
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := public.upsert_child_food_record(v_child, 'mango', date '2026-01-10', null, '第一次吃芒果', 'liked');
  v_id1 := v_row.id;
  if v_row.author_id <> v_owner or v_row.food_id <> 'mango' or v_row.reaction <> 'liked' then
    raise exception 'FAIL：新增的飲食紀錄欄位與參數不符';
  end if;
  reset role;

  -- (b) 同一位作者再次 upsert 同寶貝同食物：轉為更新，id 不變，內容整組替換
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := public.upsert_child_food_record(v_child, 'mango', date '2026-01-11', null, '改天期與備註', 'neutral');
  if v_row.id <> v_id1 then
    raise exception 'FAIL：同作者第二次 upsert 應該是同一筆（id 不變），實際 id 從 % 變成 %', v_id1, v_row.id;
  end if;
  if v_row.first_tried_on <> date '2026-01-11' or v_row.note <> '改天期與備註' or v_row.reaction <> 'neutral' then
    raise exception 'FAIL：同作者第二次 upsert 內容未正確整組替換';
  end if;
  select count(*) into v_n from public.child_food_records where child_id = v_child and food_id = 'mango';
  if v_n <> 1 then
    raise exception 'FAIL：同作者重複 upsert 後應該仍只有 1 筆，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok：同一位作者重複 upsert 同寶貝同食物——轉為更新，id 不變，內容整組替換（PUT 語意）';

  -- (c) 不同作者（非原作者、非 owner 以外——這裡用 member，且 member 本身不是
  --     owner）再對同一筆呼叫 upsert：明確 42501（不是靜默略過、也不是竄改）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_child_food_record(v_child, 'mango', date '2026-01-12', null, 'member 想改', 'disliked');
    raise exception 'FAIL：非原作者竟然可以更新別人的飲食紀錄';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  select note into v_row.note from public.child_food_records where id = v_id1;
  if v_row.note <> '改天期與備註' then
    raise exception 'FAIL：非原作者的 upsert 呼叫失敗後，內容竟然被動到了：%', v_row.note;
  end if;
  raise notice 'ok：非原作者對已有紀錄的 upsert 拿到明確 42501，內容未被竄改';

  -- (d) owner 對別人（member）記錄的紀錄呼叫 upsert：owner 不在 child_food_records_
  --     update policy 裡（票面「僅原作者可」），同樣拿 42501，不是「owner 可以蓋過」
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.upsert_child_food_record(v_child, 'pear', current_date, null, 'member 記的水梨', 'liked');
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.upsert_child_food_record(v_child, 'pear', current_date, null, 'owner 想蓋過', 'disliked');
    raise exception 'FAIL：owner 竟然可以透過 upsert 蓋過 member 記錄的飲食紀錄';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：owner 對 member 記錄的紀錄呼叫 upsert 一樣拿 42501（更新只限原作者，owner 不在這條路徑）';

  -- (e) 軟刪後可再新增：owner 軟刪 mango 這筆，之後任何 owner/member 可以再次
  --     upsert 同寶貝同食物，落地成一筆全新的列（不是還原舊列）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_child_food_record(v_id1);
  select count(*) into v_n from public.child_food_records
   where child_id = v_child and food_id = 'mango' and deleted_at is null;
  if v_n <> 0 then
    raise exception 'FAIL：軟刪後應該沒有未刪的 mango 紀錄，實際 %', v_n;
  end if;

  v_row := public.upsert_child_food_record(v_child, 'mango', current_date, null, '重新吃一次芒果', 'liked');
  if v_row.id = v_id1 then
    raise exception 'FAIL：軟刪後再次 upsert 應該是全新的一列（不同 id），實際仍是舊 id %', v_id1;
  end if;
  select count(*) into v_n from public.child_food_records
   where child_id = v_child and food_id = 'mango' and deleted_at is null;
  if v_n <> 1 then
    raise exception 'FAIL：軟刪後再次 upsert 應該有 1 筆未刪紀錄，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok：軟刪後可再新增——partial unique index 只保護未刪列，舊列與新列各自獨立';
end;
$$;

rollback;

-- ===========================================================================
-- 7. delete_child_food_record：作者本人（且仍是成員）或該家庭 owner 可軟刪；
--    非作者非 owner 被拒；owner 可移除別人的紀錄。
-- ===========================================================================
begin;

do $$
declare
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_id uuid;
  v_n int;
begin
  -- member 記錄，viewer 想刪：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := (public.upsert_child_food_record(v_child, 'tofu', current_date, null, null, null)).id;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.delete_child_food_record(v_id);
    raise exception 'FAIL：viewer（非作者非 owner）竟然可以移除飲食紀錄';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：非作者非 owner 呼叫 delete_child_food_record 拿到 42501';

  -- owner 可以移除別人（member）的紀錄
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_child_food_record(v_id);
  select count(*) into v_n from public.child_food_records where id = v_id and deleted_at is null;
  if v_n <> 0 then
    raise exception 'FAIL：owner 呼叫 delete_child_food_record 之後，這筆紀錄應該已軟刪';
  end if;
  reset role;
  raise notice 'ok：owner 可以軟刪 member 記錄的飲食紀錄';

  -- 作者本人可以自己軟刪
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := (public.upsert_child_food_record(v_child, 'shrimp', current_date, null, null, null)).id;
  perform public.delete_child_food_record(v_id);
  select count(*) into v_n from public.child_food_records where id = v_id and deleted_at is null;
  if v_n <> 0 then
    raise exception 'FAIL：作者本人呼叫 delete_child_food_record 之後應該已軟刪';
  end if;
  reset role;
  raise notice 'ok：作者本人可以軟刪自己的飲食紀錄';
end;
$$;

rollback;

-- ===========================================================================
-- 8. 時間軸（F5b）：food_first 出現／軟刪後消失、child_ids 單元素、p_child_id
--    篩選、comment_count 恆 0（含 v_has_blocks=true 分支，A 家 fixtures 本身就有
--    一組封鎖，見 00_fixtures.sql）。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_n int;
  v_child_ids uuid[];
  v_comment_count bigint;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := (public.upsert_child_food_record(v_child, 'avocado', current_date, null, '第一次吃酪梨', 'liked')).id;
  reset role;

  -- comment_count CASE 短路的回歸（merge-review R1 M1）：放一則 target_id 恰好等於
  -- 這筆 food_first ref_id 的留言（comments.target_id 沒有指向具體表的外鍵），讓
  -- comment_count 子查詢裡較便宜的 family_id／target_id 條件對 food_first 列成立、
  -- 一定會評估到 target_type 那條轉型——拿掉 CASE 短路時這裡撞 22P02，不再依賴
  -- planner 剛好選了哪支索引（fixture 資料量下 target_type 是最後才評估的 Filter，
  -- 沒有這一列就永遠評估不到，mutation 會假綠）。
  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (v_family, 'diary', v_id, 'a0000000-0000-4000-8000-000000000002', 'LS-325 cast probe');

  -- (a) 出現在「全部」時間軸，child_ids 恆為 [child]，comment_count 恆為 0
  --     （A 家 owner 在 fixtures 本身就封鎖了 viewer，這條查詢天生走
  --     v_has_blocks=true 分支，見 00_fixtures.sql：對應 20260903091317_
  --     report_block_rpc.sql 的 private.feed_item_actor_id() CASE 沒有
  --     food_first 分支會直接撞 CASE_NOT_FOUND——本段同時是那個修法的回歸測試）。
  select count(*), t.child_ids, t.comment_count into v_n, v_child_ids, v_comment_count
    from public.get_family_timeline(v_family, null, null, null, 1000) t
   where t.kind = 'food_first'::public.feed_kind and t.ref_id = v_id
   group by t.child_ids, t.comment_count;
  if v_n <> 1 then
    raise exception 'FAIL：第一次記錄應該在「全部」時間軸出現一次，實際 %', v_n;
  end if;
  if v_child_ids is distinct from array[v_child]::uuid[] then
    raise exception 'FAIL：food_first 的 child_ids 應該恆為單元素 [child]，實際 %', v_child_ids;
  end if;
  if v_comment_count <> 0 then
    raise exception 'FAIL：food_first 的 comment_count 應該恆為 0，實際 %', v_comment_count;
  end if;
  raise notice 'ok：food_first 出現在時間軸，child_ids 單元素、comment_count=0（v_has_blocks=true 分支不撞錯）';

  -- (b) p_child_id 篩選：用這個孩子篩選也會出現
  select count(*) into v_n from public.get_family_timeline(v_family, v_child, null, null, 1000)
   where kind = 'food_first'::public.feed_kind and ref_id = v_id;
  if v_n <> 1 then
    raise exception 'FAIL：用 child 篩選時，food_first 項目應該出現一次，實際 %', v_n;
  end if;
  raise notice 'ok：p_child_id 篩選對 food_first 生效';

  -- (c) 軟刪後從時間軸消失
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.delete_child_food_record(v_id);
  reset role;

  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000)
   where kind = 'food_first'::public.feed_kind and ref_id = v_id;
  if v_n <> 0 then
    raise exception 'FAIL：軟刪後 food_first 項目應該從時間軸消失，實際仍有 %', v_n;
  end if;
  raise notice 'ok：軟刪後 food_first 項目從時間軸消失';

  -- (d) 軟刪後 p_child_id 篩選也消失，在真正通過 RLS 的 authenticated 身分下呼叫
  --     （merge-review R1 informational i1：(c) 的檢查是在 reset role 之後以
  --     postgres 身分呼叫，繞過 RLS，且沒斷言 p_child_id 篩選；這裡沿用會封鎖過
  --     viewer 的 v_owner 身分，讓 v_has_blocks=true 分支也一起走到）。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, v_child, null, null, 1000)
   where kind = 'food_first'::public.feed_kind and ref_id = v_id;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：軟刪後用 p_child_id 篩選（authenticated 身分，走 RLS）food_first 項目也應該消失，實際仍有 %', v_n;
  end if;
  raise notice 'ok：軟刪後 p_child_id 篩選（authenticated 身分，走 RLS）也看不到 food_first 項目';
end;
$$;

rollback;
