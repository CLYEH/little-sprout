-- LS-48（LS-21 後端）— diaries 寫入面收斂（RPC-only）＋ get_family_timeline 驗收
--
-- 對應 20260824010000_diaries_write_path_and_timeline.sql 的每一項決定。角色矩陣沿用
-- 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3、child=2a…1；
-- 非本家庭成員用 B 家 owner（b1）代表。
--
-- 斷言依據標註慣例（LS-15 review round 2 定下）沿用：每段標明是靠本票的 migration
-- 保證，還是靠既有（LS-6／LS-33）的既有行為。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 寫入面收斂：diaries 的直接 INSERT／UPDATE 對所有角色都必須被擋（policy + grant 兩層）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_diary uuid := '5a000000-0000-4000-8000-000000000001';
  v_user text;
begin
  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003',  -- viewer
    'b0000000-0000-4000-8000-000000000001'   -- 非本家庭成員（B 家 owner）
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;

    begin
      insert into public.diaries (family_id, author_id, body)
      values (v_family, v_user::uuid, '繞過 RPC 直接寫入');
      raise exception 'FAIL：% 竟然可以直接 INSERT diaries（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    begin
      update public.diaries set body = '竄改' where id = v_diary;
      raise exception 'FAIL：% 竟然可以直接 UPDATE diaries（RPC 收斂形同虛設）', v_user;
    exception when insufficient_privilege then
      null;  -- ok
    end;

    reset role;
  end loop;

  raise notice 'ok：owner/member/viewer/非成員 對 diaries 的直接 INSERT／UPDATE 皆被擋下 (42501)';
end;
$$;

-- merge-reviewer PR #60 review F4（minor）：比照 20260823040000_invites_write_path.sql／
-- 80_join_approval.sql §11 對 invites 的兩層授權斷言慣例——上面那段驗的是「policy 擋不
-- 擋得住」，這裡另外直接驗「grant 這一層還在不在」。用 has_any_column_privilege 而不是
-- has_table_privilege：後者對欄位級 grant 回 false，若日後不小心補了一句
-- `grant insert (family_id, body) on public.diaries to authenticated` 這種欄位級授權，
-- 只驗整表的斷言測不出來（PR #55 review F1 對 invites 抓到的同一類洞，這裡照樣防一次）。
-- SELECT／DELETE 的正向對照則確保收斂沒有連帶把讀取與硬刪的路徑也關掉。
do $$
begin
  if has_any_column_privilege('authenticated', 'public.diaries', 'insert') then
    raise exception 'FAIL：authenticated 還有 diaries 的 INSERT 授權（表級或任一欄位級）—— 收斂只做了 policy 那一層，create_diary_entry 的邊界形同虛設';
  end if;
  if has_any_column_privilege('authenticated', 'public.diaries', 'update') then
    raise exception 'FAIL：authenticated 還有 diaries 的 UPDATE 授權（表級或任一欄位級）—— owner 能直接改寫別人日記內容的洞沒有真的補上';
  end if;
  if not has_table_privilege('authenticated', 'public.diaries', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 diaries 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.diaries', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 diaries 的 DELETE grant（owner 硬刪的路徑）';
  end if;
  raise notice 'ok：diaries 授權兩層對帳——INSERT/UPDATE 無任何形態的 grant，SELECT/DELETE 原樣保留（F4）';
end;
$$;

rollback;

-- ===========================================================================
-- 2. create_diary_entry：只有 contributor（owner／member）能新增，author 恆為呼叫者本人
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_other_child uuid := '2b000000-0000-4000-8000-000000000001';  -- B 家的孩子
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_author uuid;
  v_entry_date date;
begin
  -- owner 能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_diary_entry(v_family, v_child, 'owner 寫的日記', null);
  select author_id, entry_date into v_author, v_entry_date from public.diaries where id = v_id;
  if v_author <> v_owner then
    raise exception 'FAIL：author_id 應為呼叫者本人 %，實際 %', v_owner, v_author;
  end if;
  if v_entry_date <> current_date then
    raise exception 'FAIL：p_entry_date 為 NULL 時應退回 current_date（%），實際 %', current_date, v_entry_date;
  end if;
  reset role;

  -- member 能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_id := public.create_diary_entry(v_family, v_child, 'member 寫的日記', current_date - 3);
  select author_id into v_author from public.diaries where id = v_id;
  if v_author <> v_member then
    raise exception 'FAIL：member 建立的日記 author_id 不是自己';
  end if;
  reset role;
  raise notice 'ok：owner／member 都能建立日記，author_id 恆為呼叫者本人，entry_date 預設 current_date';

  -- viewer 不能寫（§3）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, 'viewer 想寫日記', null);
    raise exception 'FAIL：viewer 竟然可以建立日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  -- 非本家庭成員不能寫
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, '外人想寫日記', null);
    raise exception 'FAIL：非本家庭成員竟然可以建立日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法建立日記 (42501)';

  -- 未登入（有 authenticated session 但沒有 sub claim）
  perform set_config('request.jwt.claims', '{}', true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_child, '沒登入', null);
    raise exception 'FAIL：auth.uid() 為 NULL 時竟然建得起日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：未登入呼叫 create_diary_entry 被擋下 (42501)';

  -- child_id 必須屬於同一家庭（複合外鍵擋下跨家庭關聯）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_diary_entry(v_family, v_other_child, '想把日記掛到別家的孩子', null);
    raise exception 'FAIL：child_id 跨家庭竟然建得起日記';
  exception when foreign_key_violation then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：child_id 跨家庭被複合外鍵擋下 (23503)';
end;
$$;

rollback;

-- ===========================================================================
-- 3. update_diary_entry：只有原作者能編內容——owner 不行（這是本票要修的核心洞）
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
  v_diary uuid;
  v_body text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '原始內容', current_date);

  -- 作者本人能編
  perform public.update_diary_entry(v_diary, '作者改過的內容', current_date - 1, null);
  select body into v_body from public.diaries where id = v_diary;
  if v_body <> '作者改過的內容' then
    raise exception 'FAIL：作者編輯自己的日記沒有生效';
  end if;
  raise notice 'ok：作者本人可以編輯自己的日記內容';
  reset role;

  -- ---------------------------------------------------------------------------
  -- merge-reviewer PR #60 review F2（major）回歸：author_id 是永遠不變的歷史欄位，
  -- 授權必須另外綁定「現在還是不是這個家庭的 owner/member」。
  -- ---------------------------------------------------------------------------

  -- 已離開家庭：完全不在 family_members 裡了 → 不能再編輯自己過去寫的日記內容 (LS021)
  delete from public.family_members where family_id = v_family and user_id = v_member;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, '離開後想改', current_date, null);
    raise exception 'FAIL：已離開家庭的前作者竟然還能編輯自己過去的日記';
  exception when sqlstate 'LS021' then
    null;  -- ok
  end;
  reset role;

  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_member, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法編輯過去寫的日記內容 (LS021)——F2 回歸';

  -- 已降級 viewer：仍在 family_members 裡，只是角色變成 viewer → 同樣不能再編內容
  -- （viewer 不是 contributor，§3「Viewer 只能看與留言」——這條界線不因為「這是我
  -- 自己寫的」而放寬）
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_member;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, '降級後想改', current_date, null);
    raise exception 'FAIL：被降級成 viewer 的前作者竟然還能編輯自己過去的日記';
  exception when sqlstate 'LS021' then
    null;  -- ok
  end;
  select body into v_body from public.diaries where id = v_diary;
  if v_body <> '作者改過的內容' then
    raise exception 'FAIL：降級 viewer 的編輯嘗試竟然還是讓內容變了（應維持上一步的「作者改過的內容」，實際「%」）', v_body;
  end if;
  reset role;

  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_member;
  raise notice 'ok：被降級成 viewer 的前作者無法編輯過去寫的日記內容 (LS021)——F2 回歸';

  -- owner（非作者）不能編內容——只能透過 set_diary_deleted 移除，不能竄改
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, 'owner 竄改的內容', current_date, null);
    raise exception 'FAIL：owner 竟然可以編輯別人日記的內容（§10 授權範圍被突破）';
  exception when sqlstate 'LS021' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：owner 無法編輯非本人日記的內容 (LS021)——只保留軟刪權';

  -- viewer／非本家庭成員也不行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, 'viewer 竄改', current_date, null);
    raise exception 'FAIL：viewer 竟然可以編輯日記';
  exception when sqlstate 'LS021' then
    null;
  end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(v_diary, '外人竄改', current_date, null);
    raise exception 'FAIL：非本家庭成員竟然可以編輯日記';
  exception when sqlstate 'LS021' then
    null;
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員皆無法編輯日記 (LS021)';

  -- 不存在的日記 → LS020
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.update_diary_entry(gen_random_uuid(), '不存在', current_date, null);
    raise exception 'FAIL：編輯不存在的日記竟然沒有出錯';
  exception when sqlstate 'LS020' then
    null;
  end;

  -- 已軟刪除的日記不能編輯（即使是作者本人）
  perform public.set_diary_deleted(v_diary, true);
  begin
    perform public.update_diary_entry(v_diary, '想編輯已刪除的日記', current_date, null);
    raise exception 'FAIL：已軟刪除的日記竟然還能被編輯';
  exception when sqlstate 'LS020' then
    null;
  end;
  reset role;
  raise notice 'ok：不存在／已軟刪除的日記都無法編輯 (LS020)';
end;
$$;

rollback;

-- ===========================================================================
-- 4. set_diary_deleted：作者可動自己的，owner 可動全家任何一篇；viewer／非成員都不行
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
  v_diary uuid;
  v_deleted_at timestamptz;
  v_body text;
  v_body_before text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '會被刪又被還原的日記', current_date);

  -- 作者軟刪自己的
  perform public.set_diary_deleted(v_diary, true);
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：作者軟刪自己的日記沒有生效';
  end if;

  -- 作者還原自己的
  perform public.set_diary_deleted(v_diary, false);
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：作者還原自己的日記沒有生效';
  end if;
  raise notice 'ok：作者可以軟刪／還原自己的日記';
  reset role;

  -- viewer 不行（不是作者也不是 owner）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, true);
    raise exception 'FAIL：viewer 竟然可以軟刪別人的日記';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;

  -- 非本家庭成員不行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, true);
    raise exception 'FAIL：非本家庭成員竟然可以軟刪日記';
  exception when sqlstate '42501' then
    null;
  end;
  reset role;
  raise notice 'ok：viewer／非本家庭成員都無法軟刪日記 (42501)';

  -- owner 可以軟刪別人（member）的日記——這是 §10 授權的那件事，且只動 deleted_at。
  -- merge-reviewer PR #60 review F8：原本這裡是 `select deleted_at, body into
  -- v_deleted_at`（兩欄選進一個純量變數）——PL/pgSQL 對這種欄位數與 INTO 目標數不match
  -- 的情況不會報錯，只會靜默丟掉多出來的欄位（body 從沒被真的檢查過，實測驗證：
  -- `select now(), 'x' into v_scalar` 不會噴錯，v_scalar 只拿到第一欄）。改成
  -- 前後各存一次 body 再比對，才是真的在驗「body 沒被動到」。
  select body into v_body_before from public.diaries where id = v_diary;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  reset role;
  select deleted_at, body into v_deleted_at, v_body from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：owner 軟刪成員的日記沒有生效';
  end if;
  if v_body is distinct from v_body_before then
    raise exception 'FAIL：owner 軟刪日記時 body 被改動了（從「%」變成「%」）——set_diary_deleted 不該碰得到內容欄位',
      v_body_before, v_body;
  end if;
  raise notice 'ok：owner 可以軟刪家庭內任何一篇日記，且 body 內容逐字不變（F8 回歸）';

  -- ---------------------------------------------------------------------------
  -- merge-reviewer PR #60 review F2（major）回歸：作者分支必須綁定「現在還是不是
  -- 這個家庭的成員」，不能只認 author_id 這個永遠不變的歷史欄位。
  -- ---------------------------------------------------------------------------

  -- 已離開家庭：完全不在 family_members 裡了 → 連軟刪／還原自己過去的日記都不行 (42501)
  delete from public.family_members where family_id = v_family and user_id = v_member;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, true);
    raise exception 'FAIL：已離開家庭的前作者竟然還能軟刪自己過去的日記';
  exception when sqlstate '42501' then
    null;  -- ok
  end;
  reset role;

  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_member, 'member', true);
  raise notice 'ok：已離開家庭的前作者無法軟刪／還原過去寫的日記 (42501)——F2 回歸';

  -- 已降級 viewer：仍在 family_members 裡，只是角色變成 viewer。set_diary_deleted 的
  -- 作者分支只要求「仍是成員」，不要求 owner/member，這件事本身不受 LS-57 影響——見
  -- migration 裡寫明的產品決定；下面先驗 LS-57 新增的還原鎖，再驗「降級不影響自己
  -- 東西的處置權」這件事仍然成立。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_member;

  -- LS-57：此時 v_diary 處於 deleted=true、deleted_by=v_owner（上一段 owner 軟刪的
  -- 結果）。降級成 viewer 的前作者呼叫還原，即使通過了「仍是成員」這關，還是會被
  -- 還原鎖擋下——這篇不是他自己刪的，只有 owner 能還原。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(v_diary, false);
    raise exception 'FAIL：被降級成 viewer 的前作者，竟然還原了 owner 軟刪的日記——LS-57 的還原鎖沒有生效';
  exception when sqlstate 'LS027' then
    null;
  end;
  reset role;
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is null then
    raise exception 'FAIL：被 LS027 擋下的還原呼叫，deleted_at 竟然還是被清掉了';
  end if;
  raise notice 'ok：被降級成 viewer 的前作者無法還原 owner 軟刪的日記（LS027）——LS-57';

  -- owner 可以還原任何一篇，不限於自己刪的。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, false);
  reset role;
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：owner 還原別人日記（自己不是原作者）卻沒有生效';
  end if;
  raise notice 'ok：owner 可以還原家庭內任何一篇日記，不限於自己軟刪的——LS-57';

  -- 降級成 viewer 的作者仍可軟刪／還原「自己」設下的 deleted_at——降級本身不影響對
  -- 自己內容的處置權，這是 F2 既有結論，LS-57 沒有改變這件事，只是新增了「別人（owner）
  -- 設下的不能自行還原」這一層。
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_diary_deleted(v_diary, true);
  perform public.set_diary_deleted(v_diary, false);
  select deleted_at into v_deleted_at from public.diaries where id = v_diary;
  if v_deleted_at is not null then
    raise exception 'FAIL：被降級成 viewer 的作者，軟刪／還原自己設下的 deleted_at 卻沒有生效';
  end if;
  reset role;

  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_member;
  raise notice 'ok：被降級成 viewer 的作者仍可軟刪／還原「自己」設下的 deleted_at（只要求仍是成員，不要求 owner/member）——F2 回歸，LS-57 未改變這件事';

  -- 不存在的日記 → LS020
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.set_diary_deleted(gen_random_uuid(), true);
    raise exception 'FAIL：軟刪不存在的日記竟然沒有出錯';
  exception when sqlstate 'LS020' then
    null;
  end;
  reset role;
  raise notice 'ok：軟刪不存在的日記回報 LS020';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 硬刪（既有 diaries_delete policy，本票未動）：僅 owner，角色矩陣回歸驗證
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
  v_diary uuid;
  v_n int;
  v_user text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary := public.create_diary_entry(v_family, v_child, '硬刪測試', current_date);
  reset role;

  foreach v_user in array array[v_member::text, v_viewer::text, v_outsider::text] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    set local role authenticated;
    delete from public.diaries where id = v_diary;
    get diagnostics v_n = row_count;
    if v_n <> 0 then
      raise exception 'FAIL：% 竟然能硬刪日記（應僅 owner）', v_user;
    end if;
    reset role;
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  delete from public.diaries where id = v_diary;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 硬刪日記應影響 1 列，實際 %', v_n;
  end if;
  reset role;

  select count(*) into v_n from public.feed_items where kind = 'diary' and ref_id = v_diary;
  if v_n <> 0 then
    raise exception 'FAIL：硬刪日記後 feed_items 沒有跟著移除';
  end if;

  raise notice 'ok：硬刪日記僅 owner 能做，member／viewer／非成員皆影響 0 列；硬刪後同步從時間軸移除';
end;
$$;

rollback;

-- ===========================================================================
-- 6. get_family_timeline：混排（diary/album/media）、child 篩選、keyset 分頁、跨家庭隔離
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'fb000000-0000-4000-8000-000000000001';
  v_child1 uuid := '2a000000-0000-4000-8000-000000000001';  -- fixtures 既有的孩子
  v_child2 uuid := '2a000000-0000-4000-8000-000000000099';  -- 本檔新增的第二個孩子
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_member uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_diary_x1 uuid;
  v_diary_x2 uuid;
  v_album_x1 uuid;
  v_album_x2 uuid;
  v_media_x1 uuid;
  v_n int;
  v_full text[];
  v_collected text[] := array[]::text[];
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_iterations int := 0;
  v_page record;
  v_got_any boolean;
  v_tie_date date := current_date - 100;
begin
  -- ---- 準備資料（postgres 身分，繞過 RLS；等同 00_fixtures 的作法）--------
  insert into public.children (id, family_id, name, birthday)
  values (v_child2, v_family, '第二個孩子', date '2025-06-01');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary_x1 := public.create_diary_entry(v_family, v_child1, '今天的日記', current_date);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_diary_x2 := public.create_diary_entry(v_family, v_child2, '第二個孩子的日記', current_date - 5);
  reset role;

  -- albums 沒有 RPC（不在本票範圍），直接以 postgres 身分建立，等同既有 fixtures 慣例
  insert into public.albums (id, family_id, child_id, title, created_by, created_at)
  values (gen_random_uuid(), v_family, v_child1, '本檔新增相簿-有孩子', v_owner, now() - interval '3 hours')
  returning id into v_album_x1;
  insert into public.albums (id, family_id, child_id, title, created_by, created_at)
  values (gen_random_uuid(), v_family, null, '本檔新增相簿-全家共用', v_owner, now() - interval '10 hours')
  returning id into v_album_x2;
  insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by)
  values (gen_random_uuid(), v_family,
          v_family || '/2026/08/timeline-test.jpg', 'photo', 1024, now() - interval '2 hours',
          100, 100, v_owner)
  returning id into v_media_x1;

  -- ---- 資料量核對：4（fixtures）+ 5（本段新增：diary_x1/diary_x2/album_x1/album_x2/media_x1）= 9
  select count(*) into v_n from public.feed_items where family_id = v_family;
  if v_n <> 9 then
    raise exception 'FAIL：準備資料後 A 家 feed_items 應為 9 列，實際 %（fixtures 4 + 本段 5）', v_n;
  end if;

  -- ---- (a) p_child_id = NULL：全部 9 筆都要出現 ------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：p_child_id=NULL 應回傳 9 筆混排項目，實際 %', v_n;
  end if;
  raise notice 'ok：get_family_timeline(child=NULL) 回傳全部 9 筆混排項目（日記＋相簿＋照片）';

  -- ---- (b) p_child_id = child1：fixtures 的 album/diary（child1）+ 本段的
  --          diary_x1／album_x1（child1）= 4 筆；media 恆不出現
  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000);
  if v_n <> 4 then
    raise exception 'FAIL：p_child_id=child1 應回傳 4 筆，實際 %', v_n;
  end if;

  -- ---- (c) p_child_id = child2：只有 diary_x2 一筆 ----------------------
  select count(*) into v_n from public.get_family_timeline(v_family, v_child2, null, null, 1000);
  if v_n <> 1 then
    raise exception 'FAIL：p_child_id=child2 應回傳 1 筆，實際 %', v_n;
  end if;
  raise notice 'ok：child 篩選正確（child1=4 筆、child2=1 筆），album_x2（全家共用）與三張 media 都不落在任何 child 篩選結果裡';

  -- ---- media 在任何 child 篩選下都不出現，只在 child=NULL 時出現 ---------
  if exists (
    select 1 from public.get_family_timeline(v_family, v_child1, null, null, 1000) t where t.kind = 'media'
  ) then
    raise exception 'FAIL：child=child1 篩選下竟然出現 media 項目（media 沒有 child_id，應恆為 NULL）';
  end if;
  if not exists (
    select 1 from public.get_family_timeline(v_family, null, null, null, 1000) t
     where t.kind = 'media' and t.ref_id = v_media_x1
  ) then
    raise exception 'FAIL：child=NULL 時新增的 media 項目沒有出現在時間軸';
  end if;
  raise notice 'ok：media 項目的 child_id 恆為 NULL，只在不篩 child 時出現';

  -- ---- 軟刪日記後從「child 篩選」時間軸消失（RPC 與時間軸串接） -----------
  perform public.set_diary_deleted(v_diary_x1, true);
  select count(*) into v_n from public.get_family_timeline(v_family, v_child1, null, null, 1000);
  if v_n <> 3 then
    raise exception 'FAIL：軟刪一篇 child1 的日記後，child1 篩選應剩 3 筆，實際 %', v_n;
  end if;
  perform public.set_diary_deleted(v_diary_x1, false);  -- 還原，不影響後面的分頁/總數斷言
  raise notice 'ok：set_diary_deleted 軟刪／還原立即反映在 get_family_timeline';

  -- ---- (d) keyset 分頁：逐頁 limit=2 收集，串接結果必須與單次撈 1000 筆的
  --          結果「順序完全相同」（keyset 分頁沿用同一個排序鍵，不只是同一組集合）
  select array_agg(t.kind::text || ':' || t.ref_id::text order by t.occurred_at desc, t.ref_id desc)
    into v_full
    from public.get_family_timeline(v_family, null, null, null, 1000) t;

  loop
    v_iterations := v_iterations + 1;
    if v_iterations > 20 then
      raise exception 'FAIL：分頁超過 20 頁還沒結束，游標可能沒有前進（無限迴圈風險）';
    end if;

    v_got_any := false;
    for v_page in
      select * from public.get_family_timeline(v_family, null, v_cursor_at, v_cursor_id, 2)
    loop
      v_got_any := true;
      v_collected := v_collected || (v_page.kind::text || ':' || v_page.ref_id::text);
      v_cursor_at := v_page.occurred_at;
      v_cursor_id := v_page.ref_id;
    end loop;

    exit when not v_got_any;
  end loop;

  if v_collected is distinct from v_full then
    raise exception
      'FAIL：limit=2 逐頁串接的結果與單次撈 1000 筆不同（分頁游標可能漏項／重複／順序不一致）—— 分頁=%，完整=%',
      v_collected, v_full;
  end if;
  if array_length(v_collected, 1) <> 9 then
    raise exception 'FAIL：分頁串接後應收集到 9 筆，實際 %', array_length(v_collected, 1);
  end if;
  raise notice 'ok：keyset 分頁（limit=2）逐頁串接的結果與單次查詢完全一致（無漏項、無重複、順序相同），共 % 頁',
    v_iterations - 1;

  -- ---- (e) p_limit 邊界：<=0 夾到 1；正常值原樣通過 ----------------------
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 0);
  if v_n <> 1 then
    raise exception 'FAIL：p_limit=0 應被夾到 1，實際回傳 %', v_n;
  end if;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, -5);
  if v_n <> 1 then
    raise exception 'FAIL：p_limit=-5 應被夾到 1，實際回傳 %', v_n;
  end if;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 3);
  if v_n <> 3 then
    raise exception 'FAIL：p_limit=3 應原樣回傳 3 筆，實際 %', v_n;
  end if;
  raise notice 'ok：p_limit 下界被夾到 1（不會被誤用成「不限筆數」），正常值原樣通過';
  reset role;

  -- ---- (f) 讀取面角色回歸：member／viewer 都看得到自家時間軸 --------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：member 讀自家時間軸應為 9 筆，實際 %', v_n;
  end if;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 9 then
    raise exception 'FAIL：viewer 讀自家時間軸應為 9 筆，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok：member／viewer 都能讀到自家完整時間軸（§3：全體成員皆可看）';

  -- ---- (g) 跨家庭隔離：security invoker 完全依賴 feed_items 既有的 RLS ---
  -- A 家 owner 查 B 家的時間軸 → 0 列（RLS：private.family_ids() 不含 B 家）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family_b, null, null, null, 1000);
  if v_n <> 0 then
    raise exception 'FAIL：A 家 owner 查 B 家的時間軸竟然看得到 % 列', v_n;
  end if;
  reset role;

  -- 非本家庭成員（B 家 owner）查 A 家的時間軸 → 0 列
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 1000);
  if v_n <> 0 then
    raise exception 'FAIL：B 家 owner 查 A 家的時間軸竟然看得到 % 列', v_n;
  end if;
  reset role;
  raise notice 'ok：get_family_timeline 的跨家庭隔離由 feed_items 既有 RLS 保證（security invoker 生效）';

  -- ---------------------------------------------------------------------------
  -- (h) 平手鍵（merge-reviewer PR #60 review F6）：同一個 occurred_at 底下有多筆
  -- 項目時，keyset 游標必須靠 ref_id 當 tie-breaker，不能漏項或重複。做法：塞 3 筆
  -- entry_date 完全相同（因此 occurred_at 完全相同）的日記，用 limit=1（會讓分頁邊界
  -- 大機率剛好切在平手中間）重跑一次「單次撈 1000 筆 vs 逐頁串接」的比對——若
  -- tie-breaker 漏用 ref_id，這裡的陣列比對會不相等（漏項或重複）。
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.create_diary_entry(v_family, null, '平手鍵之一', v_tie_date);
  perform public.create_diary_entry(v_family, null, '平手鍵之二', v_tie_date);
  perform public.create_diary_entry(v_family, null, '平手鍵之三', v_tie_date);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select array_agg(t.kind::text || ':' || t.ref_id::text order by t.occurred_at desc, t.ref_id desc)
    into v_full
    from public.get_family_timeline(v_family, null, null, null, 1000) t;

  v_collected := array[]::text[];
  v_cursor_at := null;
  v_cursor_id := null;
  v_iterations := 0;
  loop
    v_iterations := v_iterations + 1;
    if v_iterations > 50 then
      raise exception 'FAIL：平手鍵分頁超過 50 頁還沒結束（游標可能沒有前進）';
    end if;
    v_got_any := false;
    for v_page in
      select * from public.get_family_timeline(v_family, null, v_cursor_at, v_cursor_id, 1)
    loop
      v_got_any := true;
      v_collected := v_collected || (v_page.kind::text || ':' || v_page.ref_id::text);
      v_cursor_at := v_page.occurred_at;
      v_cursor_id := v_page.ref_id;
    end loop;
    exit when not v_got_any;
  end loop;

  if v_collected is distinct from v_full then
    raise exception
      'FAIL：加入 3 筆同一 occurred_at 的日記後，limit=1 逐頁串接與單次查詢不同（tie-breaker 可能漏用 ref_id）—— 分頁=%，完整=%',
      v_collected, v_full;
  end if;
  if array_length(v_collected, 1) <> 12 then
    raise exception 'FAIL：加入 3 筆平手日記後應收集到 12 筆（原 9 ＋新 3），實際 %', array_length(v_collected, 1);
  end if;
  raise notice 'ok：3 筆同一 occurred_at 的日記混進資料集後，limit=1 逐頁串接仍與單次查詢完全一致（tie-breaker 正確靠 ref_id）——F6';

  -- ---------------------------------------------------------------------------
  -- child 篩選下的 keyset 分頁（merge-reviewer PR #60 review N1，major）：(d)／(h)
  -- 兩段分頁測試的 p_child_id 都是 NULL，只走過 get_family_timeline 的分支 1／2
  -- （不篩 child）；「篩 child 又帶游標」（分支 4）在這之前完全沒有被任何一次呼叫
  -- 真正執行過——這正是 review 指出的 gate 缺口：50_ 的舊探針 EXPLAIN 的是手抄 SQL
  -- 副本、不是函式本體，而這裡（行為面）也完全沒有測試涵蓋分支 4。reviewer 用
  -- mutation 證實：把分支 4 改回 OR 條件的壞寫法，這個檔案原本全綠不變。
  --
  -- 修法：複製 (d) 的比對手法，把 p_child_id 從 null 換成 v_child1，用 limit=1
  -- 逐頁走訪，驗證：串接結果＝單次查詢（無漏項無重複，證明分支 4 的游標比對正確）、
  -- 且每一列都真的屬於 child1、且不含 media（child 篩選下 media 恆不出現這件事，
  -- (c) 只驗過單次查詢，這裡在分頁路徑上再確認一次不是巧合地只在單次查詢下成立）。
  -- ---------------------------------------------------------------------------
  select array_agg(t.kind::text || ':' || t.ref_id::text order by t.occurred_at desc, t.ref_id desc)
    into v_full
    from public.get_family_timeline(v_family, v_child1, null, null, 1000) t;

  if array_length(v_full, 1) <> 4 then
    raise exception 'FAIL：child1 篩選單次查詢應為 4 筆，實際 %（前面 (b) 驗過的基準線跑掉了）',
      array_length(v_full, 1);
  end if;

  v_collected := array[]::text[];
  v_cursor_at := null;
  v_cursor_id := null;
  v_iterations := 0;
  loop
    v_iterations := v_iterations + 1;
    if v_iterations > 20 then
      raise exception 'FAIL：child1 篩選分頁超過 20 頁還沒結束（游標可能沒有前進）';
    end if;
    v_got_any := false;
    for v_page in
      select * from public.get_family_timeline(v_family, v_child1, v_cursor_at, v_cursor_id, 1)
    loop
      v_got_any := true;
      if v_page.child_id is distinct from v_child1 then
        raise exception
          'FAIL：child1 篩選＋分頁（分支 4）洩漏了其他 child／全家共用的項目（child_id=%，kind=%，ref_id=%）',
          v_page.child_id, v_page.kind, v_page.ref_id;
      end if;
      if v_page.kind = 'media' then
        raise exception 'FAIL：child1 篩選＋分頁（分支 4）竟然出現 media 項目（media 的 child_id 恆為 NULL，不該通過 child 篩選）';
      end if;
      v_collected := v_collected || (v_page.kind::text || ':' || v_page.ref_id::text);
      v_cursor_at := v_page.occurred_at;
      v_cursor_id := v_page.ref_id;
    end loop;
    exit when not v_got_any;
  end loop;

  if v_collected is distinct from v_full then
    raise exception
      'FAIL：child1 篩選下 limit=1 逐頁串接與單次查詢不同（get_family_timeline 分支 4——同時篩 child 又帶游標——可能漏項或重複）—— 分頁=%，完整=%',
      v_collected, v_full;
  end if;
  if array_length(v_collected, 1) <> 4 then
    raise exception 'FAIL：child1 篩選分頁串接後應收集到 4 筆，實際 %', array_length(v_collected, 1);
  end if;
  raise notice 'ok：child1 篩選下 limit=1 逐頁串接（get_family_timeline 分支 4：篩 child＋帶游標）與單次查詢完全一致，且未洩漏其他 child／media——N1';

  -- ---------------------------------------------------------------------------
  -- (i) p_limit 上界＝100（merge-reviewer PR #60 review F9）：先前只驗過下界
  -- （<=0 夾到 1）；上界從未用「家庭總筆數 > 100」的資料集驗證過——之前資料集只有
  -- 9～12 筆，任何 p_limit ≥ 9 都測不出上界有沒有真的生效。這裡灌 95 列不帶 child_id
  -- 的 media（不影響任何 child 篩選或計數斷言，前面全部都已經斷言完畢），把總量推過
  -- 100，才有辦法把「上界卡在 100」這件事真的測出差異。
  -- ---------------------------------------------------------------------------
  insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  select v_family, v_family || '/2026/08/limit-probe-' || i || '.jpg', 'photo', 10, 100, 100, v_owner
    from generate_series(1, 95) i;

  select count(*) into v_n from public.feed_items where family_id = v_family;
  if v_n <= 100 then
    raise exception 'FAIL：灌完 95 列 media 後 A 家 feed_items 應超過 100 列，實際 %（上界測試的前提不成立）', v_n;
  end if;

  select count(*) into v_n from public.get_family_timeline(v_family, null, null, null, 9999);
  if v_n <> 100 then
    raise exception 'FAIL：p_limit=9999 應被夾到 100，實際回傳 % 筆', v_n;
  end if;
  raise notice 'ok：p_limit 上界確實卡在 100（家庭總筆數已超過 100，p_limit=9999 仍只回傳 100 筆）——F9';

  -- ---------------------------------------------------------------------------
  -- (j) 半游標必須明確拒絕（LS022），不是靜默回空集合（merge-reviewer PR #60
  -- review F1 順帶要求：docs/API.md 已經寫「半游標不合法」，這裡驗證真的是用
  -- raise，不是回 0 列——回 0 列會讓呼叫端誤判成「這頁真的沒資料了」）。
  -- ---------------------------------------------------------------------------
  begin
    perform public.get_family_timeline(v_family, null, now(), null, 10);
    raise exception 'FAIL：只給 p_cursor_occurred_at、不給 p_cursor_ref_id 竟然沒有出錯';
  exception when sqlstate 'LS022' then
    null;  -- ok
  end;
  begin
    perform public.get_family_timeline(v_family, null, null, gen_random_uuid(), 10);
    raise exception 'FAIL：只給 p_cursor_ref_id、不給 p_cursor_occurred_at 竟然沒有出錯';
  exception when sqlstate 'LS022' then
    null;  -- ok
  end;
  reset role;
  raise notice 'ok：半游標（游標兩參數只給其中一個）明確拒絕，回報 LS022，不是靜默回空集合';
end;
$$;

rollback;

-- ===========================================================================
-- 7. feed_items.child_id 的回填冪等性與孩子刪除的 FK 行為（merge-reviewer PR #60
--    review N4）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_child uuid := '2a000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_new_child uuid;
  v_diary uuid;
  v_album uuid;
  v_before_diary uuid;
  v_before_album uuid;
  v_after_family_diary uuid;
  v_after_child_diary uuid;
  v_after_family_album uuid;
  v_after_child_album uuid;
  v_n int;
begin
  -- ---------------------------------------------------------------------------
  -- (a) 回填冪等性：把 fixtures 既有 diary/album 對應的 feed_items.child_id 手動
  -- 清成 NULL，重新執行一次跟 20260824010000_diaries_write_path_and_timeline.sql
  -- 逐字一致的回填 UPDATE 語句，驗證正確地從 diaries/albums 補回 child_id，且再跑
  -- 一次影響 0 列（真正的冪等定義，不只是「跑了不會錯」）。
  --
  -- 為什麼 fresh reset 測不出這件事：migration 套用當下 diaries/albums 都還沒有
  -- 資料，回填當下等於是 no-op，從未真的補過任何一列——F3（第 1 輪 review）當時
  -- 只交付了回填 SQL 本身，沒有測試證明「這段 UPDATE 對已存在、child_id 已是 NULL
  -- 的列」是正確且冪等的。
  -- ---------------------------------------------------------------------------
  update public.feed_items
     set child_id = null
   where family_id = v_family and kind in ('diary', 'album');

  select count(*) into v_n from public.feed_items
   where family_id = v_family and kind in ('diary', 'album') and child_id is not null;
  if v_n <> 0 then
    raise exception 'FAIL：手動清空後應該 0 列還帶 child_id，實際 %', v_n;
  end if;

  update public.feed_items f
     set child_id = d.child_id
    from public.diaries d
   where f.kind = 'diary' and f.ref_id = d.id
     and f.child_id is distinct from d.child_id;

  update public.feed_items f
     set child_id = a.child_id
    from public.albums a
   where f.kind = 'album' and f.ref_id = a.id
     and f.child_id is distinct from a.child_id;

  select count(*) into v_n from public.feed_items
   where family_id = v_family and kind in ('diary', 'album') and child_id is distinct from v_child;
  if v_n <> 0 then
    raise exception 'FAIL：回填後 A 家的 diary/album feed_items 應全部補回 child_id=%，實際有 % 列不是', v_child, v_n;
  end if;

  update public.feed_items f
     set child_id = d.child_id
    from public.diaries d
   where f.kind = 'diary' and f.ref_id = d.id
     and f.child_id is distinct from d.child_id;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：diary 回填 UPDATE 重跑一次應影響 0 列（冪等），實際影響 % 列', v_n;
  end if;

  update public.feed_items f
     set child_id = a.child_id
    from public.albums a
   where f.kind = 'album' and f.ref_id = a.id
     and f.child_id is distinct from a.child_id;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：album 回填 UPDATE 重跑一次應影響 0 列（冪等），實際影響 % 列', v_n;
  end if;

  raise notice 'ok：feed_items.child_id 的回填 UPDATE 正確補回既有資料，且重跑一次影響 0 列（冪等）——N4';

  -- ---------------------------------------------------------------------------
  -- (b) 刪除孩子：feed_items.family_id 保留、child_id 變 NULL，delete 本身不噴
  -- 23502。驗證 feed_items_child_same_family_fkey 的 `on delete set null (child_id)`
  -- column-specific 寫法——若漏寫 `(child_id)`，Postgres 對複合外鍵 ON DELETE SET
  -- NULL 的預設行為是把「所有」參照欄位都設成 NULL，會連 family_id 一起 NULL 掉，
  -- 而 feed_items.family_id 是 NOT NULL，會直接噴 23502。這條在 migration 裡原本
  -- 只靠註解推理說明，這裡補機械驗證，不是只靠人看得懂那段註解就信任它。
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.children (id, family_id, name, birthday)
  values (gen_random_uuid(), v_family, '即將被刪除的孩子', date '2024-01-01')
  returning id into v_new_child;
  v_diary := public.create_diary_entry(v_family, v_new_child, '掛在即將被刪的孩子底下', current_date);
  reset role;

  -- albums 沒有 RPC（不在本票範圍），直接以 postgres 身分建立，等同既有 fixtures 慣例
  insert into public.albums (id, family_id, child_id, title, created_by)
  values (gen_random_uuid(), v_family, v_new_child, '也掛在即將被刪的孩子底下', v_owner)
  returning id into v_album;

  select f.child_id into v_before_diary from public.feed_items f
   where f.kind = 'diary' and f.ref_id = v_diary;
  select f.child_id into v_before_album from public.feed_items f
   where f.kind = 'album' and f.ref_id = v_album;
  if v_before_diary <> v_new_child or v_before_album <> v_new_child then
    raise exception 'FAIL：刪除孩子之前，日記／相簿的 feed_items.child_id 應該是新孩子 id（diary=%，album=%）',
      v_before_diary, v_before_album;
  end if;

  -- 真正的斷言就是這句 DELETE 本身：若 FK 的 ON DELETE SET NULL 沒有正確地只設
  -- child_id 一欄，這句會直接噴 23502，讓整個測試檔案失敗——不需要額外包
  -- exception 區塊，讓錯誤自然傳播就是測試本身。
  delete from public.children where id = v_new_child;

  select f.family_id, f.child_id into v_after_family_diary, v_after_child_diary
    from public.feed_items f where f.kind = 'diary' and f.ref_id = v_diary;
  select f.family_id, f.child_id into v_after_family_album, v_after_child_album
    from public.feed_items f where f.kind = 'album' and f.ref_id = v_album;

  if v_after_family_diary <> v_family or v_after_family_album <> v_family then
    raise exception 'FAIL：刪除孩子後 feed_items.family_id 應該原封不動保留（diary=%，album=%，期望 %）',
      v_after_family_diary, v_after_family_album, v_family;
  end if;
  if v_after_child_diary is not null or v_after_child_album is not null then
    raise exception 'FAIL：刪除孩子後 feed_items.child_id 應該被設成 NULL（diary=%，album=%）',
      v_after_child_diary, v_after_child_album;
  end if;

  raise notice 'ok：刪除孩子後 feed_items.family_id 保留、child_id 變 NULL，且刪除本身沒有噴 23502——N4';
end;
$$;

rollback;
