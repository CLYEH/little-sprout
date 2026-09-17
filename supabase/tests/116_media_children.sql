-- LS-317（LS-249 後端先行）—— media ↔ 孩子標記驗收
--
-- 對應 supabase/migrations/20260917155738_media_children.sql 的每一項決定。角色矩陣
-- 沿用 00_fixtures.sql 的 A 家：owner=a1、member=a2（can_upload=true，上傳者，擁有
-- 3a...0002）、viewer=a3、非本家庭成員用 B 家 owner（b1）代表；A 家另一筆既有 media
-- 3a...0001 由 a1（owner）本人上傳。97_multi_child_tags.sql 已經覆蓋 diary_children／
-- album_children 的等價場景，這裡專注在 media 版本的差異：
--   1. media_children 的 RPC-only 收斂（直接寫入被擋，SELECT 三角色皆可讀）。
--   2. set_media_children 的完整角色矩陣——授權門檻沿 media_update policy（上傳者
--      本人＋當下仍有上傳權，或該家庭 owner），跟 set_album_children 的「建立者
--      分支」不同，需要獨立驗證（含 can_upload 被關掉後的上傳者）。
--   3. 覆蓋語意（刪多補少、去重、跨家庭 23503、LS044）。
--   4. set_media_children_batch 的批次原子性——一筆壞 child 全部 rollback（含
--      LS044、跨家庭 23503、單一元素授權不足三種成因）。
--   5. 時間軸：media 項目的 child_ids 回填＋p_child_id 篩選（LS-121 當時 media 恆
--      不出現的限制，本票起解除）。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. media_children：直接 INSERT/UPDATE/DELETE 對所有角色皆被擋（policy 沒開，
--    也沒有任何寫入 grant）；SELECT 三角色（含 viewer）皆可讀。
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_media uuid := '3a000000-0000-4000-8000-000000000001';
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
      insert into public.media_children (family_id, media_id, child_id)
      values (v_family, v_media, v_child);
      raise exception 'FAIL：% 竟然可以直接 INSERT media_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      delete from public.media_children where media_id = v_media and child_id = v_child;
      raise exception 'FAIL：% 竟然可以直接 DELETE media_children（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 media_children 的直接 INSERT／DELETE 皆被擋下 (42501)';
end;
$$;

do $$
begin
  if has_any_column_privilege('authenticated', 'public.media_children', 'insert')
     or has_any_column_privilege('authenticated', 'public.media_children', 'update')
     or has_table_privilege('authenticated', 'public.media_children', 'delete') then
    raise exception 'FAIL：authenticated 對 media_children 仍有寫入授權（表級或欄位級）';
  end if;
  if not has_table_privilege('authenticated', 'public.media_children', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 media_children 的 SELECT grant';
  end if;
  raise notice 'ok：media_children 授權兩層對帳——INSERT/UPDATE/DELETE 無任何形態的 grant，SELECT 保留';
end;
$$;

-- owner 設定標記後，viewer（含）三角色都能直接 SELECT 讀到（同家庭任一角色）。
do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_user text;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_media_children(v_media, array[v_child]::uuid[]);
  reset role;

  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000002',
    'a0000000-0000-4000-8000-000000000003'
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_n from public.media_children where media_id = v_media and child_id = v_child;
    if v_n <> 1 then
      raise exception 'FAIL：% 讀不到 owner 剛設定的 media_children 標記（RLS SELECT 矩陣）', v_user;
    end if;
    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer 三角色皆可直接 SELECT media_children（同家庭任一角色）';
end;
$$;

rollback;

-- ===========================================================================
-- 2. set_media_children：角色矩陣（上傳者本人／owner／非上傳者非owner／
--    非本家庭成員／未登入／照片不存在／上傳者被關 can_upload）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_uploader uuid := 'a0000000-0000-4000-8000-000000000002';  -- member，3a...0002 的上傳者
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_media_by_uploader uuid := '3a000000-0000-4000-8000-000000000002';  -- uploaded_by = v_uploader
  v_media_by_owner uuid := '3a000000-0000-4000-8000-000000000001';     -- uploaded_by = v_owner
  v_n int;
begin
  -- 上傳者本人：能設定自己上傳的照片
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uploader, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_media_children(v_media_by_uploader, array[v_child1]::uuid[]);
  reset role;

  select count(*) into v_n from public.media_children where media_id = v_media_by_uploader;
  if v_n <> 1 then
    raise exception 'FAIL：上傳者呼叫 set_media_children 應該成功標記 1 個孩子，實際 %', v_n;
  end if;

  -- owner：能設定「別人上傳」的照片（owner 對任何一張都有處置權，同 media_update policy）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_media_children(v_media_by_uploader, array[v_child1]::uuid[]);
  reset role;
  raise notice 'ok：owner 可以設定別人上傳的照片的寶貝標記';

  -- 非上傳者、非 owner（同家庭 member 對別人上傳的照片）：42501
  -- （用 v_uploader 去動 v_media_by_owner，v_uploader 不是這張的上傳者，也不是 owner）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uploader, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children(v_media_by_owner, array[v_child1]::uuid[]);
    raise exception 'FAIL：非上傳者、非 owner 的 member 竟然可以設定別人照片的寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- viewer：42501（viewer 從不是上傳者，也不是 owner）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children(v_media_by_owner, array[v_child1]::uuid[]);
    raise exception 'FAIL：viewer 竟然可以設定照片的寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children(v_media_by_owner, array[v_child1]::uuid[]);
    raise exception 'FAIL：非本家庭成員竟然可以設定照片的寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 未登入：42501
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.set_media_children(v_media_by_owner, array[v_child1]::uuid[]);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然可以設定寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 照片不存在：裸 42501（不另開新碼，見 migration 檔頭第 4 段）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children(gen_random_uuid(), array[v_child1]::uuid[]);
    raise exception 'FAIL：不存在的照片竟然沒有出錯';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  raise notice 'ok：set_media_children 角色矩陣——上傳者本人／owner 可設定；非上傳者非owner 的 member／viewer／非本家庭成員／未登入／照片不存在皆拿 42501';

  -- 上傳者被 owner 關掉 can_upload 之後：連自己上傳的照片都不能再設定標記
  -- （同 media_update policy 的既定行為，20_role_permissions.sql 已驗證等價情境）。
  update public.family_members set can_upload = false
   where family_id = v_family and user_id = v_uploader;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uploader, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children(v_media_by_uploader, array[v_child1]::uuid[]);
    raise exception 'FAIL：can_upload 被關掉之後，上傳者竟然還能設定自己照片的寶貝標記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  update public.family_members set can_upload = true
   where family_id = v_family and user_id = v_uploader;  -- 還原，避免影響後續斷言

  raise notice 'ok：can_upload 被 owner 關掉之後，上傳者本人也不能再設定自己照片的寶貝標記 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 覆蓋語意（刪多補少、去重、NULL／空陣列清空、跨家庭 23503、LS044）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_child2 uuid;
  v_child3 uuid;
  v_other_family_child uuid := '2b000000-0000-4000-8000-000000000001';  -- B 家的孩子
  v_n int;
  v_ids uuid[];
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_child2 := public.create_child(v_family, '覆蓋測試孩子二', date '2024-05-01', null);
  v_child3 := public.create_child(v_family, '覆蓋測試孩子三', date '2024-06-01', null);

  -- (a) 帶重複值＋NULL 元素：應該去重、過濾 NULL，只留 2 個孩子
  perform public.set_media_children(v_media, array[v_child1, v_child1, null, v_child2]::uuid[]);
  select array_agg(child_id order by child_id) into v_ids
    from public.media_children where media_id = v_media;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child1, v_child2]) x) then
    raise exception 'FAIL：set_media_children 應該去重＋過濾 NULL 只留 [child1, child2]，實際 %', v_ids;
  end if;

  -- (b) 全覆蓋成 {child2, child3}：child1 被刪、child3 被補、child2 保留不變
  perform public.set_media_children(v_media, array[v_child2, v_child3, v_child2]::uuid[]);  -- 故意帶重複值
  select array_agg(child_id order by child_id) into v_ids
    from public.media_children where media_id = v_media;
  if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child2, v_child3]) x) then
    raise exception 'FAIL：set_media_children 覆蓋後應該是 [child2, child3]，實際 %', v_ids;
  end if;

  -- (c) 傳空陣列＝清空
  perform public.set_media_children(v_media, array[]::uuid[]);
  select count(*) into v_n from public.media_children where media_id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL：set_media_children 傳空陣列應該清空所有標記，實際還有 % 個', v_n;
  end if;

  -- (d) 傳 NULL＝清空（跟空陣列同義）；先補回一個孩子才有東西可清
  perform public.set_media_children(v_media, array[v_child1]::uuid[]);
  perform public.set_media_children(v_media, null);
  select count(*) into v_n from public.media_children where media_id = v_media;
  if v_n <> 0 then
    raise exception 'FAIL：set_media_children 傳 NULL 應該清空所有標記，實際還有 % 個', v_n;
  end if;

  -- (e) 跨家庭：23503
  begin
    perform public.set_media_children(v_media, array[v_other_family_child]::uuid[]);
    raise exception 'FAIL：child_id 跨家庭竟然設定成功了';
  exception when foreign_key_violation then
    null;  -- ok
  end;

  -- (f) 指向已軟刪的孩子：LS044
  perform public.set_child_deleted(v_child3, true);
  begin
    perform public.set_media_children(v_media, array[v_child3]::uuid[]);
    raise exception 'FAIL：指向已軟刪的孩子竟然設定成功了';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;

  reset role;
  raise notice 'ok：set_media_children 覆蓋語意——去重、過濾 NULL、刪多補少、空陣列／NULL 清空、跨家庭 23503、已軟刪孩子 LS044，皆正確';
end;
$$;

rollback;

-- ===========================================================================
-- 4. set_media_children_batch：批次原子性——一筆壞 child 全部 rollback
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_uploader uuid := 'a0000000-0000-4000-8000-000000000002';
  v_media1 uuid := '3a000000-0000-4000-8000-000000000001';  -- uploaded_by = v_owner
  v_media2 uuid := '3a000000-0000-4000-8000-000000000002';  -- uploaded_by = v_uploader
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_other_family_child uuid := '2b000000-0000-4000-8000-000000000001';
  v_child_deleted uuid;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_child_deleted := public.create_child(v_family, '批次測試已軟刪孩子', date '2024-07-01', null);
  perform public.set_child_deleted(v_child_deleted, true);

  -- (a) 第一筆合法（child1），第二筆跨家庭 23503：整批 rollback，含第一筆也不落地
  begin
    perform public.set_media_children_batch(jsonb_build_array(
      jsonb_build_object('media_id', v_media1, 'child_ids', jsonb_build_array(v_child1)),
      jsonb_build_object('media_id', v_media2, 'child_ids', jsonb_build_array(v_other_family_child))
    ));
    raise exception 'FAIL：批次裡含跨家庭 child 竟然整批成功了';
  exception when foreign_key_violation then
    null;  -- ok
  end;

  select count(*) into v_n from public.media_children where media_id in (v_media1, v_media2);
  if v_n <> 0 then
    raise exception 'FAIL：批次第二筆跨家庭失敗後，第一筆（本應成功）竟然還留下 % 筆——原子性沒做到', v_n;
  end if;

  -- (b) 第一筆合法，第二筆指向已軟刪孩子 LS044：整批 rollback
  begin
    perform public.set_media_children_batch(jsonb_build_array(
      jsonb_build_object('media_id', v_media1, 'child_ids', jsonb_build_array(v_child1)),
      jsonb_build_object('media_id', v_media2, 'child_ids', jsonb_build_array(v_child_deleted))
    ));
    raise exception 'FAIL：批次裡含已軟刪孩子竟然整批成功了';
  exception when sqlstate 'LS044' then
    null;  -- ok
  end;

  select count(*) into v_n from public.media_children where media_id in (v_media1, v_media2);
  if v_n <> 0 then
    raise exception 'FAIL：批次第二筆 LS044 失敗後，第一筆竟然還留下 % 筆——原子性沒做到', v_n;
  end if;

  -- (c) 第一筆合法（v_uploader 是 v_media2 的上傳者），第二筆 v_uploader 對 v_media1
  -- 既非上傳者也非 owner：整批因授權不足 rollback
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uploader, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_media_children_batch(jsonb_build_array(
      jsonb_build_object('media_id', v_media2, 'child_ids', jsonb_build_array(v_child1)),
      jsonb_build_object('media_id', v_media1, 'child_ids', jsonb_build_array(v_child1))
    ));
    raise exception 'FAIL：批次裡含授權不足的一筆竟然整批成功了';
  exception when sqlstate '42501' then
    null;  -- ok
  end;

  select count(*) into v_n from public.media_children where media_id in (v_media1, v_media2);
  if v_n <> 0 then
    raise exception 'FAIL：批次第二筆授權不足失敗後，第一筆竟然還留下 % 筆——原子性沒做到', v_n;
  end if;
  reset role;

  -- (d) 全部合法：兩筆都落地（驗證正向路徑，不是只驗失敗）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_media_children_batch(jsonb_build_array(
    jsonb_build_object('media_id', v_media1, 'child_ids', jsonb_build_array(v_child1)),
    jsonb_build_object('media_id', v_media2, 'child_ids', jsonb_build_array(v_child1))
  ));
  reset role;

  select count(*) into v_n from public.media_children where media_id in (v_media1, v_media2) and child_id = v_child1;
  if v_n <> 2 then
    raise exception 'FAIL：批次兩筆皆合法時應該各自成功標記，實際共 % 筆', v_n;
  end if;

  raise notice 'ok：set_media_children_batch 批次原子性——跨家庭 23503／已軟刪孩子 LS044／單筆授權不足 42501 皆整批 rollback（含較早的合法筆一起消失）；全合法時正向成功';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 時間軸：media 項目的 child_ids 回填＋p_child_id 篩選（LS-121 當時的
--    「media 一律不出現」限制，本票起解除）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';
  v_child2 uuid;
  v_tagged_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_untagged_media uuid := '3a000000-0000-4000-8000-000000000002';
  v_n int;
  v_child_ids uuid[];
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  v_child2 := public.create_child(v_family, '時間軸 media 標記孩子', date '2024-08-01', null);
  perform public.set_media_children(v_tagged_media, array[v_child1, v_child2]::uuid[]);

  -- (a)「全部」：這張照片只出現一次，child_ids 含兩個孩子
  -- （不用 array_agg(child_ids)——child_ids 本身已經是 uuid[]，array_agg 一個
  -- 陣列型別的欄位會疊成二維陣列，單一下標 [1] 在二維陣列上取不到第一列、
  -- 只會得到 NULL；篩選條件已經保證恰好一列，直接 SELECT INTO 即可）
  select count(*) into v_n
    from public.get_family_timeline(v_family, null, null, null, 1000)
   where kind = 'media'::public.feed_kind and ref_id = v_tagged_media;
  select t.child_ids into v_child_ids
    from public.get_family_timeline(v_family, null, null, null, 1000) t
   where t.kind = 'media'::public.feed_kind and t.ref_id = v_tagged_media;
  if v_n <> 1 then
    raise exception 'FAIL：標記過的照片在「全部」時間軸應該只出現一次，實際 %', v_n;
  end if;
  if v_child_ids is distinct from (select array_agg(x order by x) from unnest(array[v_child1, v_child2]) x) then
    raise exception 'FAIL：標記過的照片 child_ids 應該是 [child1, child2]，實際 %', v_child_ids;
  end if;

  -- (b) 用 child1 篩選：這張照片出現一次（LS-121 起 media 一律不出現的限制，本票解除）
  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000)
   where kind = 'media'::public.feed_kind and ref_id = v_tagged_media;
  if v_n <> 1 then
    raise exception 'FAIL：用 child1 篩選時，標記過 child1 的照片應該出現一次，實際 %（media 應已解除恆不出現限制）', v_n;
  end if;

  -- (c) 用 child2 篩選：同樣出現一次（不是被 child1 篩選「用掉」）
  select count(*) into v_n from public.get_family_timeline(v_family, v_child2, null, null, 1000)
   where kind = 'media'::public.feed_kind and ref_id = v_tagged_media;
  if v_n <> 1 then
    raise exception 'FAIL：用 child2 篩選時，標記過 child2 的照片應該出現一次，實際 %', v_n;
  end if;

  -- (d) 未標記的照片：child_ids 恆為空陣列，且 child1／child2 篩選下都不出現
  select t.child_ids into v_child_ids
    from public.get_family_timeline(v_family, null, null, null, 1000) t
   where t.kind = 'media'::public.feed_kind and t.ref_id = v_untagged_media;
  if v_child_ids is distinct from '{}'::uuid[] then
    raise exception 'FAIL：未標記的照片 child_ids 應該是空陣列，實際 %', v_child_ids;
  end if;

  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000)
   where kind = 'media'::public.feed_kind and ref_id = v_untagged_media;
  if v_n <> 0 then
    raise exception 'FAIL：未標記的照片用 child1 篩選竟然出現了，實際 %', v_n;
  end if;

  raise notice 'ok：get_family_timeline 的 media 項目 child_ids 正確回填、p_child_id 篩選對 media 生效（標記過出現、未標記不出現）';
end;
$$;

rollback;
