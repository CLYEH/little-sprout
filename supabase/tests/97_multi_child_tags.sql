-- LS-121（LS-21 後端）— 日記／相簿多寶貝標記驗收
--
-- 對應 supabase/migrations/20260902011514_diary_album_multi_child_tags.sql 的每一項
-- 決定。角色矩陣沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3、
-- child=2a…1；非本家庭成員用 B 家 owner（b1）代表。85_diaries_timeline.sql／
-- 95_children_backend.sql 已經覆蓋 create_diary_entry／update_diary_entry 的角色
-- 矩陣與 LS044（連結表版本），這裡專注在票面第 6 點裡那三塊尚未被涵蓋的部分：
--   1. diary_children／album_children 的 RPC-only 收斂（直接寫入被擋）。
--   2. set_album_children 的完整角色矩陣（新 RPC，先前沒有任何測試涵蓋）。
--   3. 覆蓋語意（刪多補少、去重、跨家庭 23503）在「多個孩子」情境下的完整驗證
--      （既有測試多半只驗單一孩子）。
--   4. 時間軸：同一篇內容標 2 個孩子時「全部」只出現一次、兩個孩子篩選各出現一次，
--      且 `child_ids` 陣列正確。
--   5. keyset 分頁在多孩子標記下不跳項（灌量）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. diary_children／album_children：直接 INSERT/UPDATE/DELETE 對所有角色皆被擋
--    （policy 沒開，也沒有任何 grant——見 §2「寫入路徑小結」）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_diary uuid := '5a000000-0000-4000-8000-000000000001';
  v_album uuid := '4a000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_user text;
begin
  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003',  -- viewer
    'b0000000-0000-4000-8000-000000000001'   -- 非本家庭成員
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;

    begin
      insert into public.diary_children (family_id, diary_id, child_id)
      values (v_family, v_diary, v_child);
      raise exception 'FAIL：% 竟然可以直接 INSERT diary_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      delete from public.diary_children where diary_id = v_diary and child_id = v_child;
      raise exception 'FAIL：% 竟然可以直接 DELETE diary_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      insert into public.album_children (family_id, album_id, child_id)
      values (v_family, v_album, v_child);
      raise exception 'FAIL：% 竟然可以直接 INSERT album_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      delete from public.album_children where album_id = v_album and child_id = v_child;
      raise exception 'FAIL：% 竟然可以直接 DELETE album_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 diary_children／album_children 的直接 INSERT／DELETE 皆被擋下 (42501)';
end;
$$;

do $$
begin
  if has_any_column_privilege('authenticated', 'public.diary_children', 'insert')
     or has_any_column_privilege('authenticated', 'public.diary_children', 'update')
     or has_table_privilege('authenticated', 'public.diary_children', 'delete') then
    raise exception 'FAIL：authenticated 對 diary_children 仍有寫入授權（表級或欄位級）';
  end if;
  if has_any_column_privilege('authenticated', 'public.album_children', 'insert')
     or has_any_column_privilege('authenticated', 'public.album_children', 'update')
     or has_table_privilege('authenticated', 'public.album_children', 'delete') then
    raise exception 'FAIL：authenticated 對 album_children 仍有寫入授權（表級或欄位級）';
  end if;
  if not has_table_privilege('authenticated', 'public.diary_children', 'select')
     or not has_table_privilege('authenticated', 'public.album_children', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 diary_children／album_children 的 SELECT grant';
  end if;
  raise notice 'ok：diary_children／album_children 授權兩層對帳——INSERT/UPDATE/DELETE 無任何形態的 grant，SELECT 保留';
end;
$$;

rollback;

-- ===========================================================================
-- 2. set_album_children：角色矩陣（建立者／owner／member／viewer／已離開的建立者／
--    非本家庭成員）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_creator uuid := 'a0000000-0000-4000-8000-000000000002';  -- member，本段的建立者
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_album uuid;
  v_n int;
begin
  -- 建立者本人建立相簿（未變，直接 .insert()，不經 RPC）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_creator, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.albums (family_id, title, created_by)
  values (v_family, '角色矩陣測試相簿', v_creator)
  returning id into v_album;

  -- 建立者本人：能設定
  perform public.set_album_children(v_album, array[v_child1]::uuid[]);
  reset role;

  select count(*) into v_n from public.album_children where album_id = v_album;
  if v_n <> 1 then
    raise exception 'FAIL：建立者呼叫 set_album_children 應該成功標記 1 個孩子，實際 %', v_n;
  end if;

  -- viewer（非建立者）：LS045——授權檢查刻意是單一合併碼（同 update_diary_entry
  -- 的 LS021／update_comment 的 LS025 慣例：「不是建立者」與「是建立者但已不是
  -- owner/member」共用同一個碼，不區分成不同錯誤碼，呼叫端不會從碼的差異推敲出
  -- 「這本相簿本來是不是我的」）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child1]::uuid[]);
    raise exception 'FAIL：viewer 竟然可以設定別人相簿的寶貝標記';
  exception when sqlstate 'LS045' then
    null;  -- ok
  end;
  reset role;

  -- owner（非建立者）：LS045——owner 對別人相簿只有移除／還原權，沒有內容編輯權
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child1]::uuid[]);
    raise exception 'FAIL：owner 竟然可以設定別人相簿的寶貝標記（應該跟編輯 title 一樣被擋）';
  exception when sqlstate 'LS045' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員：同樣是 LS045（不是 42501）——這支 RPC 的授權檢查不分「完全的
  -- 外人」與「認識但不是建立者的成員」，見上方 viewer 分支的說明
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child1]::uuid[]);
    raise exception 'FAIL：非本家庭成員竟然可以設定相簿的寶貝標記';
  exception when sqlstate 'LS045' then
    null;  -- ok
  end;
  reset role;

  -- 未登入
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child1]::uuid[]);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然可以設定寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 相簿不存在：LS023
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_creator, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(gen_random_uuid(), array[v_child1]::uuid[]);
    raise exception 'FAIL：不存在的相簿竟然沒有出錯';
  exception when sqlstate 'LS023' then
    null;  -- ok
  end;
  reset role;

  -- 建立者被降級成 viewer：不能再設定（跟編輯 title 的授權門檻一致）。降級本身要用
  -- postgres 身分（繞過 family_members_update 的 owner-only policy——用建立者自己的
  -- 身分下這句 UPDATE 會被 RLS 靜默篩成 0 列，降級不會真的發生，後面的斷言就測不到）。
  set local role postgres;
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_creator;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_creator, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_album_children(v_album, array[v_child1]::uuid[]);
    raise exception 'FAIL：建立者被降級成 viewer 之後竟然還能設定寶貝標記';
  exception when sqlstate 'LS045' then
    null;  -- ok
  end;
  reset role;

  set local role postgres;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_creator;  -- 還原，避免影響後續斷言
  reset role;

  raise notice 'ok：set_album_children 角色矩陣——建立者本人可設定；owner（非建立者）拿 LS045；viewer／非本家庭成員／未登入拿 42501；相簿不存在拿 LS023；建立者降級後拿 LS045';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 覆蓋語意（刪多補少、去重、NULL／空陣列清空、跨家庭 23503）——用多個孩子驗證
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_child2 uuid;
  v_child3 uuid;
  v_other_family_child uuid := '2b000000-0000-4000-8000-000000000001';  -- B 家的孩子
  v_diary uuid;
  v_album uuid;
  v_n int;
  v_ids uuid[];
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_child2 := public.create_child(v_family, '覆蓋測試孩子二', date '2024-05-01', null);
  v_child3 := public.create_child(v_family, '覆蓋測試孩子三', date '2024-06-01', null);

  -- (a) 建立時就帶重複值＋NULL 元素：應該去重、過濾 NULL，只留 2 個孩子
  v_diary := public.create_diary_entry(
    v_family, array[v_child1, v_child1, null, v_child2]::uuid[], '建立時帶重複與 NULL', current_date);
  select array_agg(child_id order by child_id) into v_ids
    from public.diary_children where diary_id = v_diary;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child1, v_child2]) x) then
    raise exception 'FAIL：create_diary_entry 應該去重＋過濾 NULL 只留 [child1, child2]，實際 %', v_ids;
  end if;

  -- (b) update_diary_entry 全覆蓋成 {child2, child3}：child1 被刪、child3 被補、
  -- child2 保留不變（刪多補少）
  perform public.update_diary_entry(v_diary, '覆蓋成 child2+child3', current_date,
    array[v_child2, v_child3, v_child2]::uuid[]);  -- 故意帶重複值
  select array_agg(child_id order by child_id) into v_ids
    from public.diary_children where diary_id = v_diary;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child2, v_child3]) x) then
    raise exception 'FAIL：update_diary_entry 覆蓋後應該是 [child2, child3]（child1 被刪、child3 被補、child2 保留、重複值去重），實際 %', v_ids;
  end if;

  -- (c) 傳空陣列＝清空
  perform public.update_diary_entry(v_diary, '清空標記', current_date, array[]::uuid[]);
  select count(*) into v_n from public.diary_children where diary_id = v_diary;
  if v_n <> 0 then
    raise exception 'FAIL：update_diary_entry 傳空陣列應該清空所有標記，實際還有 % 個', v_n;
  end if;

  -- (d) 傳 NULL＝清空（跟空陣列同義）；先補回一個孩子才有東西可清
  perform public.update_diary_entry(v_diary, '先補一個', current_date, array[v_child1]::uuid[]);
  perform public.update_diary_entry(v_diary, '傳 NULL 清空', current_date, null);
  select count(*) into v_n from public.diary_children where diary_id = v_diary;
  if v_n <> 0 then
    raise exception 'FAIL：update_diary_entry 傳 NULL 應該清空所有標記，實際還有 % 個', v_n;
  end if;

  -- (e) 跨家庭：23503
  begin
    perform public.update_diary_entry(v_diary, '想標到別家的孩子', current_date,
      array[v_other_family_child]::uuid[]);
    raise exception 'FAIL：child_id 跨家庭竟然覆蓋成功了';
  exception when foreign_key_violation then
    null;  -- ok
  end;

  raise notice 'ok：update_diary_entry 覆蓋語意——去重、過濾 NULL、刪多補少、空陣列／NULL 清空、跨家庭 23503，皆正確（diary 版）';

  -- (f) set_album_children 同一套語意
  insert into public.albums (family_id, title, created_by)
  values (v_family, '覆蓋語意測試相簿', v_owner)
  returning id into v_album;

  perform public.set_album_children(v_album, array[v_child1, v_child1, null, v_child2]::uuid[]);
  select array_agg(child_id order by child_id) into v_ids
    from public.album_children where album_id = v_album;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child1, v_child2]) x) then
    raise exception 'FAIL：set_album_children 應該去重＋過濾 NULL 只留 [child1, child2]，實際 %', v_ids;
  end if;

  perform public.set_album_children(v_album, array[v_child2, v_child3]::uuid[]);
  select array_agg(child_id order by child_id) into v_ids
    from public.album_children where album_id = v_album;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child2, v_child3]) x) then
    raise exception 'FAIL：set_album_children 覆蓋後應該是 [child2, child3]，實際 %', v_ids;
  end if;

  perform public.set_album_children(v_album, array[]::uuid[]);
  select count(*) into v_n from public.album_children where album_id = v_album;
  if v_n <> 0 then
    raise exception 'FAIL：set_album_children 傳空陣列應該清空所有標記，實際還有 % 個', v_n;
  end if;

  begin
    perform public.set_album_children(v_album, array[v_other_family_child]::uuid[]);
    raise exception 'FAIL：set_album_children 標到別家的孩子竟然成功了';
  exception when foreign_key_violation then
    null;  -- ok
  end;

  reset role;
  raise notice 'ok：set_album_children 覆蓋語意——去重、過濾 NULL、刪多補少、空陣列清空、跨家庭 23503，皆正確（album 版）';
end;
$$;

rollback;

-- ===========================================================================
-- 4. 時間軸：同一篇內容標 2 個孩子時，「全部」只出現一次、兩個孩子篩選各出現一次，
--    child_ids 陣列正確；並用一批灌量資料驗 keyset 分頁在多孩子標記下不跳項
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_child2 uuid;
  v_diary uuid;
  v_album uuid;
  v_n int;
  v_child_ids uuid[];
  v_full text[];
  v_collected text[];
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_iterations int;
  v_page record;
  v_got_any boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_child2 := public.create_child(v_family, '時間軸雙標記孩子', date '2024-07-01', null);

  -- 一篇日記、一本相簿都標兩個孩子
  v_diary := public.create_diary_entry(v_family, array[v_child1, v_child2]::uuid[],
    '雙標記日記', current_date);
  insert into public.albums (family_id, title, created_by)
  values (v_family, '雙標記相簿', v_owner)
  returning id into v_album;
  perform public.set_album_children(v_album, array[v_child1, v_child2]::uuid[]);

  -- (a)「全部」：這篇日記／這本相簿各只出現一次
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000)
   where (kind = 'diary'::public.feed_kind and ref_id = v_diary)
      or (kind = 'album'::public.feed_kind and ref_id = v_album);
  if v_n <> 2 then
    raise exception 'FAIL：雙標記的日記＋相簿在「全部」時間軸應各出現一次（合計 2），實際 %', v_n;
  end if;

  -- (b) 用 child1 篩選：各出現一次，且 child_ids 陣列同時含 child1／child2
  select child_ids into v_child_ids from public.get_family_timeline(v_family, v_child1, null, null, 1000)
   where kind = 'diary' and ref_id = v_diary;
  if v_child_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child1, v_child2]) x) then
    raise exception 'FAIL：用 child1 篩選時，雙標記日記的 child_ids 應該是 [child1, child2]，實際 %', v_child_ids;
  end if;

  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000)
   where (kind = 'diary'::public.feed_kind and ref_id = v_diary)
      or (kind = 'album'::public.feed_kind and ref_id = v_album);
  if v_n <> 2 then
    raise exception 'FAIL：用 child1 篩選時，雙標記的日記＋相簿應各出現一次，實際 %', v_n;
  end if;

  -- (c) 用 child2 篩選：同樣各出現一次（不是被 child1 篩選「用掉」）
  select count(*) into v_n from public.get_family_timeline(v_family, v_child2, null, null, 1000)
   where (kind = 'diary'::public.feed_kind and ref_id = v_diary)
      or (kind = 'album'::public.feed_kind and ref_id = v_album);
  if v_n <> 2 then
    raise exception 'FAIL：用 child2 篩選時，雙標記的日記＋相簿應各出現一次，實際 %', v_n;
  end if;

  raise notice 'ok：雙標記內容在「全部」時間軸只出現一次，兩個孩子個別篩選各出現一次，child_ids 陣列正確含兩個孩子';

  -- ---------------------------------------------------------------------------
  -- (d) keyset 分頁灌量：40 篇日記，交錯標記 child1／child2／兩者都標／都不標，
  -- 驗證 child1 篩選下逐頁串接（limit=3）與單次撈 1000 筆完全一致（無跳項無重複）。
  -- 「單次撈 1000 筆」不預先手算期望筆數（family 裡還有 00_fixtures 既有的
  -- child1 標記與本段前面 (a)-(c) 建立的雙標記日記／相簿，逐一手算容易漏算）——
  -- 真正的斷言是「逐頁串接＝單次查詢」本身，不是筆數對不對，筆數只用下界做
  -- 灌量前提是否成立的粗略自檢（至少要看到這 20 篇新灌的）。
  -- ---------------------------------------------------------------------------
  for v_n in 1..40 loop
    if v_n % 4 = 0 then
      perform public.create_diary_entry(v_family, array[v_child1, v_child2]::uuid[],
        '灌量-both-' || v_n, current_date - v_n);
    elsif v_n % 4 = 1 then
      perform public.create_diary_entry(v_family, array[v_child1]::uuid[],
        '灌量-child1-' || v_n, current_date - v_n);
    elsif v_n % 4 = 2 then
      perform public.create_diary_entry(v_family, array[v_child2]::uuid[],
        '灌量-child2-' || v_n, current_date - v_n);
    else
      perform public.create_diary_entry(v_family, null,
        '灌量-none-' || v_n, current_date - v_n);
    end if;
  end loop;

  select array_agg(t.kind::text || ':' || t.ref_id::text order by t.occurred_at desc, t.ref_id desc)
    into v_full
    from public.get_family_timeline(v_family, v_child1, null, null, 1000) t;

  if array_length(v_full, 1) < 20 then
    raise exception 'FAIL：灌量後 child1 篩選單次查詢應至少有 20 筆（本段迴圈新灌的），實際 %（灌量前提不成立）',
      array_length(v_full, 1);
  end if;

  v_collected := array[]::text[];
  v_cursor_at := null;
  v_cursor_id := null;
  v_iterations := 0;
  loop
    v_iterations := v_iterations + 1;
    if v_iterations > 50 then
      raise exception 'FAIL：child1 篩選灌量分頁超過 50 頁還沒結束（游標可能沒有前進）';
    end if;
    v_got_any := false;
    for v_page in
      select * from public.get_family_timeline(v_family, v_child1, v_cursor_at, v_cursor_id, 3)
    loop
      v_got_any := true;
      if not (v_child1 = any(v_page.child_ids)) then
        raise exception 'FAIL：child1 篩選灌量分頁洩漏了未標記 child1 的項目（child_ids=%）', v_page.child_ids;
      end if;
      v_collected := v_collected || (v_page.kind::text || ':' || v_page.ref_id::text);
      v_cursor_at := v_page.occurred_at;
      v_cursor_id := v_page.ref_id;
    end loop;
    exit when not v_got_any;
  end loop;

  if v_collected is distinct from v_full then
    raise exception
      'FAIL：child1 篩選灌量下 limit=3 逐頁串接與單次查詢不同（可能漏項或重複）—— 分頁=%，完整=%',
      v_collected, v_full;
  end if;

  reset role;
  raise notice 'ok：child1 篩選在 % 筆灌量資料下，limit=3 逐頁串接與單次查詢完全一致（無跳項無重複）', array_length(v_full, 1);
end;
$$;

rollback;
