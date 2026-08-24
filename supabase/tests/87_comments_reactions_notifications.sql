-- LS-58（LS-22 後端切片）— comments／reactions 寫入 RPC、留言分頁讀取、reaction 彙總、
-- notification_events 資料面＋RLS 驗收
--
-- 對應 20260825020000_comments_reactions_notifications.sql 的每一項決定。角色矩陣沿用
-- 00_fixtures.sql 的 A 家：owner=a1、member=a2、viewer=a3；額外在各段自己的交易內加一位
-- 「A 家第 4 位成員」a4（非作者、非 owner 的 member，跟 86_ 的既有慣例一致）；非本家庭
-- 成員用 B 家 owner（b1）代表。每段各自 begin/rollback，互不依賴前一段留下的狀態。
--
-- 斷言依據標註慣例（LS-15 review round 2 定下）沿用：每段標明是靠本票的 migration
-- 保證，還是靠既有行為。
--
-- ---------------------------------------------------------------------------
-- Mutation 自證（開發期用本機 Supabase CLI 映像實跑 `supabase db reset` +
-- `supabase/tests/run.sh` 手動驗證，非本檔自動執行）：
--   M1：拿掉 toggle_reaction 裡的 `perform pg_advisory_xact_lock(...)`
--       → supabase/tests/concurrency/reaction_toggle_race_s2.sql 的斷言變紅——
--         S2 不再被阻塞在鎖上，改成被 unique index 插入等待卡住（時序仍然
--         被拖住，時間門檻沒被穿透），但解除阻塞後撞
--         reactions_target_user_key 的 23505，S2 的「v_error is not null」
--         斷言精準抓到（實測：`錯誤碼=23505`，不是「無，成功」）。
--   M2：拿掉 update_comment 裡的作者／成員授權檢查（`if v_comment.author_id
--       is distinct from v_uid or not exists (...) then raise ...`）
--       → 本檔 §3「非作者的 member／viewer／非本家庭成員呼叫 update_comment
--         皆 LS025」的斷言變紅（非作者也能改到內容）。
--   M3：拿掉 update_comment 的 SELECT ... FOR UPDATE 鎖（改成不鎖的裸 SELECT）
--       → supabase/tests/concurrency/comment_edit_vs_delete_s2_delete.sql
--         這組（軟刪先動，作者編輯必須被阻塞後拿到已軟刪除前的資料一致性）
--         的「等待秒數 < 0.5」斷言變紅——S2 不再被 S1 的 set_comment_deleted
--         阻塞，兩者交錯執行。
-- 三個 mutation 都各自單獨套用（其餘保持修好的版本）、跑 `supabase db reset`
-- 套用到真實 schema、再跑 `run.sh` 全套，確認精準命中對應斷言、其餘斷言正常
-- 通過，套用後已改回原狀。
-- ---------------------------------------------------------------------------

\set ON_ERROR_STOP on

-- ===========================================================================
-- §1. comments／reactions 授權兩層對帳（LS-58 收斂）
-- ===========================================================================
begin;

do $$
begin
  -- comments：INSERT／UPDATE（表級或任一欄位級）皆不得有 grant；SELECT／DELETE 原樣保留。
  if has_any_column_privilege('authenticated', 'public.comments', 'insert') then
    raise exception 'FAIL：authenticated 還有 comments 的 INSERT 授權（表級或任一欄位級）—— create_comment 的邊界形同虛設';
  end if;
  if has_any_column_privilege('authenticated', 'public.comments', 'update') then
    raise exception 'FAIL：authenticated 還有 comments 的 UPDATE 授權（表級或任一欄位級）—— update_comment 的邊界形同虛設';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 SELECT grant';
  end if;
  if not has_table_privilege('authenticated', 'public.comments', 'delete') then
    raise exception 'FAIL 回歸：authenticated 失去 comments 的 DELETE grant（owner 硬刪的路徑）';
  end if;
  raise notice 'ok：comments 授權兩層對帳——INSERT/UPDATE 無任何形態的 grant，SELECT/DELETE 原樣保留';

  -- reactions：INSERT／DELETE 皆不得有 grant；SELECT 原樣保留。
  if has_any_column_privilege('authenticated', 'public.reactions', 'insert') then
    raise exception 'FAIL：authenticated 還有 reactions 的 INSERT 授權——toggle_reaction 的邊界形同虛設';
  end if;
  if has_table_privilege('authenticated', 'public.reactions', 'delete') then
    raise exception 'FAIL：authenticated 還有 reactions 的 DELETE 授權——toggle_reaction 的邊界形同虛設';
  end if;
  if not has_table_privilege('authenticated', 'public.reactions', 'select') then
    raise exception 'FAIL 回歸：authenticated 失去 reactions 的 SELECT grant';
  end if;
  raise notice 'ok：reactions 授權兩層對帳——INSERT/DELETE 無任何形態的 grant，SELECT 原樣保留';

  -- 直接 INSERT／UPDATE 在 policy 層也必須被擋（跟 grant 層是兩道獨立防線，見
  -- docs/API.md §2「判斷一張表能不能直接 .insert()」的說明）。
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  begin
    insert into public.comments (family_id, target_type, target_id, author_id, body)
    values ('fa000000-0000-4000-8000-000000000001', 'media',
            '3a000000-0000-4000-8000-000000000001',
            'a0000000-0000-4000-8000-000000000001', '繞過 RPC 直接寫入');
    raise exception 'FAIL：owner 竟然可以直接 INSERT comments（RPC 收斂形同虛設）';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.reactions (family_id, target_type, target_id, user_id)
    values ('fa000000-0000-4000-8000-000000000001', 'media',
            '3a000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：owner 竟然可以直接 INSERT reactions（RPC 收斂形同虛設）';
  exception when insufficient_privilege then
    null;
  end;

  reset role;
  raise notice 'ok：owner 對 comments／reactions 的直接 INSERT 皆被 policy 擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- §2. create_comment：任何角色（含 viewer）都能留言，author_id 恆為呼叫者本人
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_target uuid := '3a000000-0000-4000-8000-000000000001';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_comment_id uuid;
  v_author uuid;
begin
  -- owner／member／viewer 皆可留言
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  select public.create_comment(v_family, 'media', v_target, 'owner 的留言') into v_comment_id;
  reset role;
  select author_id into v_author from public.comments where id = v_comment_id;
  if v_author <> 'a0000000-0000-4000-8000-000000000001' then
    raise exception 'FAIL：create_comment 的 author_id 沒有恆為呼叫者本人（owner）';
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;
  select public.create_comment(v_family, 'media', v_target, 'member 的留言') into v_comment_id;
  reset role;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;
  select public.create_comment(v_family, 'media', v_target, 'viewer 的留言') into v_comment_id;
  reset role;
  select author_id into v_author from public.comments where id = v_comment_id;
  if v_author <> 'a0000000-0000-4000-8000-000000000003' then
    raise exception 'FAIL：create_comment 的 author_id 沒有恆為呼叫者本人（viewer）';
  end if;
  raise notice 'ok：owner／member／viewer 都能呼叫 create_comment，author_id 恆為呼叫者本人（PLAN §3：viewer 也能留言）';

  -- 非本家庭成員：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.create_comment(v_family, 'media', v_target, '外人的留言');
    raise exception 'FAIL：非本家庭成員竟然可以呼叫 create_comment';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：非本家庭成員呼叫 create_comment 應該是 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：非本家庭成員呼叫 create_comment 被擋下 (42501)';

  -- 未登入：42501
  perform set_config('request.jwt.claims', '', true);
  begin
    perform public.create_comment(v_family, 'media', v_target, '匿名的留言');
    raise exception 'FAIL：未登入竟然可以呼叫 create_comment';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：未登入呼叫 create_comment 應該是 42501，實際 %', sqlstate;
    end if;
  end;
  raise notice 'ok：未登入呼叫 create_comment 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- §3. update_comment：角色矩陣（作者本人／owner／member／viewer／非本家庭成員／
--     已離開／降級），不存在，已軟刪除仍可編輯（刻意不比照 diaries）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_owner uuid := 'a0000000-0000-4000-8000-000000000001';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_other_member uuid := 'a0000000-0000-4000-8000-000000000004';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_target uuid := '3a000000-0000-4000-8000-000000000001';
  v_comment uuid;
  v_body text;
  v_err text;
begin
  set local role postgres;
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (v_other_member, '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 'a4-member@ls58.test', now(), now(), '{}', '{}');
  insert into public.profiles (id, display_name) values (v_other_member, 'A 家第 4 位成員');
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_other_member, 'member', true);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select public.create_comment(v_family, 'media', v_target, '原始留言') into v_comment;
  reset role;

  -- 作者本人：放行
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.update_comment(v_comment, '作者改過的留言');
  reset role;
  select body into v_body from public.comments where id = v_comment;
  if v_body <> '作者改過的留言' then
    raise exception 'FAIL：作者本人呼叫 update_comment 應該成功，body 卻是「%」', v_body;
  end if;
  raise notice 'ok：作者本人可以用 update_comment 編輯自己的留言';

  -- owner（非作者）：LS025
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment(v_comment, 'owner 竄改的留言');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  select body into v_body from public.comments where id = v_comment;
  if v_err <> 'LS025' or v_body <> '作者改過的留言' then
    raise exception 'FAIL：owner（非作者）呼叫 update_comment 應該是 LS025 且內容不變，實際錯誤碼=%，body=「%」', v_err, v_body;
  end if;
  raise notice 'ok：owner（非作者）呼叫 update_comment 拿到 LS025，內容逐字不變——本票要修的核心洞';

  -- member（非作者、非 owner）／viewer／非本家庭成員：皆 LS025
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other_member, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment(v_comment, 'member 竄改的留言');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  if v_err <> 'LS025' then
    raise exception 'FAIL：非作者的 member 呼叫 update_comment 應該是 LS025，實際 %', v_err;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment(v_comment, 'viewer 竄改的留言');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  if v_err <> 'LS025' then
    raise exception 'FAIL：非作者的 viewer 呼叫 update_comment 應該是 LS025，實際 %', v_err;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment(v_comment, '外人竄改的留言');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  if v_err <> 'LS025' then
    raise exception 'FAIL：非本家庭成員呼叫 update_comment 應該是 LS025，實際 %', v_err;
  end if;
  raise notice 'ok：非作者的 member／viewer／非本家庭成員呼叫 update_comment 皆 LS025';

  -- 作者已離開家庭：LS025
  delete from public.family_members where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment(v_comment, '離開後想改');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  if v_err <> 'LS025' then
    raise exception 'FAIL：已離開家庭的前作者呼叫 update_comment 應該是 LS025，實際 %', v_err;
  end if;
  insert into public.family_members (family_id, user_id, role, can_upload)
  values (v_family, v_author, 'member', true);
  raise notice 'ok：已離開家庭的前作者呼叫 update_comment 拿到 LS025';

  -- 作者被降級成 viewer：update_comment 的作者分支只要求「仍是任一角色的成員」
  -- （跟收斂前 comments_update policy 的作者分支一致，不是本票放寬）。
  update public.family_members set role = 'viewer'
   where family_id = v_family and user_id = v_author;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.update_comment(v_comment, '降級後仍可改');
  reset role;
  select body into v_body from public.comments where id = v_comment;
  if v_body <> '降級後仍可改' then
    raise exception 'FAIL：被降級成 viewer 的前作者呼叫 update_comment 應該仍然成功，實際 body=「%」', v_body;
  end if;
  update public.family_members set role = 'member'
   where family_id = v_family and user_id = v_author;
  raise notice 'ok：被降級成 viewer 的前作者仍可用 update_comment 編輯自己的留言（作者分支只要求仍是任一角色的成員，跟收斂前一致）';

  -- 不存在的留言：LS024
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_err := null;
  begin
    perform public.update_comment('00000000-0000-4000-8000-000000000099', '不存在');
  exception when others then v_err := sqlstate;
  end;
  reset role;
  if v_err <> 'LS024' then
    raise exception 'FAIL：update_comment 對不存在的留言應該回報 LS024，實際 %', v_err;
  end if;
  raise notice 'ok：update_comment 對不存在的留言回報 LS024';

  -- 已軟刪除的留言仍可編輯（刻意不比照 update_diary_entry，見 migration 說明）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_author, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_comment_deleted(v_comment, true);
  perform public.update_comment(v_comment, '軟刪後仍能改');
  reset role;
  select body, deleted_at into v_body from public.comments where id = v_comment;
  if v_body <> '軟刪後仍能改' then
    raise exception 'FAIL：已軟刪除的留言呼叫 update_comment 應該仍然成功，實際 body=「%」', v_body;
  end if;
  raise notice 'ok：已軟刪除的留言仍可用 update_comment 編輯內容（刻意不比照 diaries 的限制）';
end;
$$;

rollback;

-- ===========================================================================
-- §4. toggle_reaction：任何角色可按讚、非本家庭成員被擋、序列化雙 toggle 的
--     順序冪等性（sequential，真正的併發回歸在
--     supabase/tests/concurrency/reaction_toggle_race_*.sql）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_target uuid := '3a000000-0000-4000-8000-000000000002';  -- 用一張還沒被 fixtures 按過的照片
  v_viewer uuid := 'a0000000-0000-4000-8000-000000000003';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_result boolean;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 第一次：加入
  select public.toggle_reaction(v_family, 'media', v_target) into v_result;
  if v_result is not true then
    raise exception 'FAIL：第一次 toggle_reaction 應該回傳 true（加入），實際 %', v_result;
  end if;
  select count(*) into v_n from public.reactions
   where target_type = 'media' and target_id = v_target and user_id = v_viewer;
  if v_n <> 1 then
    raise exception 'FAIL：第一次 toggle_reaction 之後應該有 1 筆反應，實際 %', v_n;
  end if;

  -- 第二次：收回（冪等——不是撞 23505，是乾淨地回到「沒按過」的狀態）
  select public.toggle_reaction(v_family, 'media', v_target) into v_result;
  if v_result is not false then
    raise exception 'FAIL：第二次 toggle_reaction 應該回傳 false（收回），實際 %', v_result;
  end if;
  select count(*) into v_n from public.reactions
   where target_type = 'media' and target_id = v_target and user_id = v_viewer;
  if v_n <> 0 then
    raise exception 'FAIL：第二次 toggle_reaction 之後應該歸零，實際剩下 %', v_n;
  end if;

  -- 第三次：再加回去，確認不是「只能按一次」的單向操作
  select public.toggle_reaction(v_family, 'media', v_target) into v_result;
  if v_result is not true then
    raise exception 'FAIL：第三次 toggle_reaction（收回後再按）應該回傳 true，實際 %', v_result;
  end if;
  reset role;
  raise notice 'ok：toggle_reaction 冪等——加入／收回／再加入三次呼叫皆正確翻轉，無 23505';

  -- viewer 可以按讚（PLAN §3）
  raise notice 'ok：viewer 可以呼叫 toggle_reaction（上面的呼叫者本身就是 viewer）';

  -- 非本家庭成員：42501
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.toggle_reaction(v_family, 'media', v_target);
    raise exception 'FAIL：非本家庭成員竟然可以呼叫 toggle_reaction';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：非本家庭成員呼叫 toggle_reaction 應該是 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：非本家庭成員呼叫 toggle_reaction 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- §5. get_reaction_counts：批次彙總，無反應的 target_id 不出現（呼叫端當 0）
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  v_target1 uuid := '3a000000-0000-4000-8000-000000000001';  -- fixtures 已有 a3 按過一次
  v_target2 uuid := '3a000000-0000-4000-8000-000000000002';  -- 這裡再加兩個反應
  v_target3 uuid := '4a000000-0000-4000-8000-000000000001';  -- 完全沒有反應
  v_count1 bigint;
  v_count2 bigint;
  v_reacted1 boolean;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  perform public.toggle_reaction(v_family, 'media', v_target2);
  reset role;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;
  perform public.toggle_reaction(v_family, 'media', v_target2);
  reset role;

  -- 以 a3（fixtures 裡對 v_target1 按過讚的人）身分呼叫，驗 reacted_by_me
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;

  select count(*) into v_n from public.get_reaction_counts(
    v_family, 'media', array[v_target1, v_target2, v_target3]);
  if v_n <> 2 then
    raise exception 'FAIL：get_reaction_counts 應該只回傳 2 筆（v_target3 無反應不該出現），實際 %', v_n;
  end if;

  select reaction_count, reacted_by_me into v_count1, v_reacted1
    from public.get_reaction_counts(v_family, 'media', array[v_target1, v_target2, v_target3])
   where target_id = v_target1;
  if v_count1 <> 1 or v_reacted1 is not true then
    raise exception 'FAIL：v_target1 應該是 1 筆反應且 reacted_by_me=true（a3 自己按的），實際 count=%，reacted=%', v_count1, v_reacted1;
  end if;

  select reaction_count into v_count2
    from public.get_reaction_counts(v_family, 'media', array[v_target1, v_target2, v_target3])
   where target_id = v_target2;
  if v_count2 <> 2 then
    raise exception 'FAIL：v_target2 應該是 2 筆反應，實際 %', v_count2;
  end if;

  reset role;
  raise notice 'ok：get_reaction_counts 正確彙總（v_target1=1/reacted_by_me、v_target2=2、v_target3 不出現）';
end;
$$;

rollback;

-- ===========================================================================
-- §6. list_comments：keyset 分頁、軟刪過濾、作者顯示名、同秒平手鍵、半游標拒絕
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  -- 用 3a…0002：00_fixtures.sql 只在 3a…0001 上放了一則既有留言（6a…），這裡選一個
  -- 乾淨的 target 才能用「精確 5 則」這種斷言，不必去扣掉 fixtures 帶來的既有列。
  v_target uuid := '3a000000-0000-4000-8000-000000000002';
  v_author uuid := 'a0000000-0000-4000-8000-000000000002';
  v_outsider uuid := 'b0000000-0000-4000-8000-000000000001';
  v_base timestamptz := now() - interval '1 hour';
  v_ids uuid[];
  v_id uuid;
  v_page1 uuid[];
  v_page2 uuid[];
  v_all uuid[];
  v_cursor_created_at timestamptz;
  v_cursor_id uuid;
  v_deleted_id uuid;
  v_name text;
  v_n int;
begin
  -- 5 則留言，其中 3 則刻意同一秒（同秒平手鍵要靠 id 排序），直接用 postgres 寫死
  -- created_at 才能控制順序（create_comment 的 created_at 用預設值 now()，這裡要的
  -- 是可預期的固定排序，同 85_ 對 diaries 分頁測試的既有作法）。
  set local role postgres;
  for v_id in
    insert into public.comments (family_id, target_type, target_id, author_id, body, created_at)
    select v_family, 'media', v_target, v_author, 'list_comments 測試 #' || i,
           case when i <= 3 then v_base else v_base + (i - 3) * interval '1 minute' end
      from generate_series(1, 5) i
    returning id
  loop
    v_ids := array_append(v_ids, v_id);
  end loop;

  -- 額外一則已軟刪除的留言，必須被 list_comments 濾掉
  insert into public.comments (family_id, target_type, target_id, author_id, body, deleted_at)
  values (v_family, 'media', v_target, v_author, '已刪除，不該出現', now())
  returning id into v_deleted_id;
  reset role;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;

  -- 作者顯示名：left join profiles 正確帶出
  select author_display_name into v_name
    from public.list_comments(v_family, 'media', v_target, null, null, 20)
   where id = v_ids[5];
  if v_name <> 'A 家媽媽' then
    raise exception 'FAIL：list_comments 的 author_display_name 沒有正確帶出（實際「%」）', v_name;
  end if;

  -- 逐頁串接（limit=2）必須與單次查詢（limit=20）完全一致，且不含已軟刪除的那則
  select array_agg(id) into v_all
    from public.list_comments(v_family, 'media', v_target, null, null, 20);
  if v_deleted_id = any (v_all) then
    raise exception 'FAIL：list_comments 洩漏了已軟刪除的留言';
  end if;
  if array_length(v_all, 1) <> 5 then
    raise exception 'FAIL：list_comments 應該回傳 5 則未刪除的留言，實際 %', array_length(v_all, 1);
  end if;

  v_page1 := array(select id from public.list_comments(v_family, 'media', v_target, null, null, 2));
  v_cursor_created_at := (select created_at from public.comments where id = v_page1[2]);
  v_cursor_id := v_page1[2];
  v_page2 := array(select id from public.list_comments(
    v_family, 'media', v_target, v_cursor_created_at, v_cursor_id, 2));

  if v_page1 || v_page2 || array(select id from public.list_comments(
       v_family, 'media', v_target,
       (select created_at from public.comments where id = v_page2[2]), v_page2[2], 2))
     <> v_all then
    raise exception 'FAIL：list_comments 逐頁串接（limit=2）與單次查詢（limit=20）不一致——分頁或同秒平手鍵有問題';
  end if;
  raise notice 'ok：list_comments 逐頁串接（limit=2，含 3 則同秒留言）與單次查詢完全一致，且已軟刪除的留言被濾掉';

  -- 半游標拒絕：LS022
  begin
    perform public.list_comments(v_family, 'media', v_target, now(), null, 20);
    raise exception 'FAIL：list_comments 半游標應該被拒絕';
  exception when others then
    if sqlstate <> 'LS022' then
      raise exception 'FAIL：list_comments 半游標應該回報 LS022，實際 %', sqlstate;
    end if;
  end;
  raise notice 'ok：list_comments 半游標明確拒絕，回報 LS022，不是靜默回空集合';

  reset role;

  -- 非本家庭成員：42501（list_comments 改成 security definer 後，這是函式內部
  -- 手動檢查的結果，不是 RLS 靜默回空集合——見 migration 對這支函式的裁量說明）
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.list_comments(v_family, 'media', v_target, null, null, 20);
    raise exception 'FAIL：非本家庭成員竟然可以呼叫 list_comments';
  exception when others then
    if sqlstate <> '42501' then
      raise exception 'FAIL：非本家庭成員呼叫 list_comments 應該是 42501，實際 %', sqlstate;
    end if;
  end;
  reset role;
  raise notice 'ok：非本家庭成員呼叫 list_comments 被擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- §7. notification_events：trigger 事件產生與 5 分鐘視窗合併、kind 分開累計、RLS
-- ===========================================================================
begin;

do $$
declare
  v_family uuid := 'fa000000-0000-4000-8000-000000000001';
  -- 用 3a…0002：00_fixtures.sql 在 3a…0001 上已經放了一則留言與一筆反應（6a…／7a…，
  -- 由 postgres 直接寫入，一樣會觸發本票新增的 AFTER INSERT trigger），若沿用
  -- 3a…0001 會讓「第一則留言」其實合併進 fixtures 那筆待送事件，event_count 從 2
  -- 起跳，斷言就對不上「這是全新事件」的前提。
  v_target uuid := '3a000000-0000-4000-8000-000000000002';
  v_diary_id uuid;
  v_album_id uuid;
  v_comment_id uuid;
  v_n int;
  v_count int;
  v_actor uuid;
begin
  -- 留言：第一次產生一筆待送事件
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;
  select public.create_comment(v_family, 'media', v_target, '第一則留言') into v_comment_id;
  reset role;

  set local role postgres;
  select count(*), max(event_count) into v_n, v_count from public.notification_events
   where kind = 'comment' and target_type = 'media' and target_id = v_target;
  reset role;
  if v_n <> 1 or v_count <> 1 then
    raise exception 'FAIL：第一則留言之後應該有 1 筆待送事件、event_count=1，實際 %/%', v_n, v_count;
  end if;

  -- 第二次留言（5 分鐘內）：合併，event_count=2，actor 換成最新觸發者
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;
  perform public.create_comment(v_family, 'media', v_target, '第二則留言（5 分鐘內）');
  reset role;

  set local role postgres;
  select count(*) into v_n
    from public.notification_events
   where kind = 'comment' and target_type = 'media' and target_id = v_target;
  select event_count, actor_id into v_count, v_actor
    from public.notification_events
   where kind = 'comment' and target_type = 'media' and target_id = v_target;
  reset role;
  if v_n <> 1 or v_count <> 2 or v_actor <> 'a0000000-0000-4000-8000-000000000003' then
    raise exception 'FAIL：5 分鐘內第二則留言應該合併成同一筆（event_count=2，actor 換成最新觸發者），實際 n=%/count=%/actor=%', v_n, v_count, v_actor;
  end if;
  raise notice 'ok：同一 target 5 分鐘內的多則留言合併成一筆待送事件（event_count 累加、actor 更新）';

  -- 手動把這筆事件的 occurred_at 推到 6 分鐘前（模擬視窗已過），第三則留言必須開新的一筆
  set local role postgres;
  update public.notification_events
     set occurred_at = now() - interval '6 minutes'
   where kind = 'comment' and target_type = 'media' and target_id = v_target;
  reset role;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;
  perform public.create_comment(v_family, 'media', v_target, '第三則留言（視窗已過）');
  reset role;

  set local role postgres;
  select count(*) into v_n from public.notification_events
   where kind = 'comment' and target_type = 'media' and target_id = v_target;
  reset role;
  if v_n <> 2 then
    raise exception 'FAIL：視窗已過（>5 分鐘）之後的新留言應該開新的一筆待送事件，最終應有 2 筆，實際 %', v_n;
  end if;
  raise notice 'ok：超過 5 分鐘滾動視窗之後的新事件不會合併，開新的一筆待送事件';

  -- 按讚：獨立的 kind，不會跟同一個 target 的留言事件混在一起
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  perform public.toggle_reaction(v_family, 'media', v_target);
  reset role;

  set local role postgres;
  select count(*) into v_n from public.notification_events
   where kind = 'reaction' and target_type = 'media' and target_id = v_target;
  reset role;
  if v_n <> 1 then
    raise exception 'FAIL：按讚應該產生獨立 kind=reaction 的待送事件，實際 %', v_n;
  end if;
  raise notice 'ok：留言與按讚各自累計成不同 kind 的事件，不會互相合併';

  -- 新日記／新相簿：target 是內容自己
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  select public.create_diary_entry(v_family, null, '通知測試日記', current_date) into v_diary_id;
  insert into public.albums (family_id, title, created_by)
  values (v_family, '通知測試相簿', 'a0000000-0000-4000-8000-000000000001')
  returning id into v_album_id;
  reset role;

  set local role postgres;
  select count(*) into v_n from public.notification_events
   where kind = 'diary' and target_type = 'diary' and target_id = v_diary_id;
  if v_n <> 1 then
    raise exception 'FAIL：新日記應該產生 kind=diary、target_id=該篇日記自己 id 的事件，實際 %', v_n;
  end if;
  select count(*) into v_n from public.notification_events
   where kind = 'album' and target_type = 'album' and target_id = v_album_id;
  if v_n <> 1 then
    raise exception 'FAIL：新相簿應該產生 kind=album、target_id=該本相簿自己 id 的事件，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok：新日記／新相簿各自產生以自己 id 為 target 的待送事件';
end;
$$;

-- RLS／grant：成員完全不可讀寫 notification_events，只有 service role（postgres 在
-- 本機測試環境代表 service_role 等級的存取）才看得到。
do $$
begin
  if has_table_privilege('authenticated', 'public.notification_events', 'select') then
    raise exception 'FAIL：authenticated 竟然有 notification_events 的 SELECT grant——成員不該讀得到推播佇列';
  end if;
  if has_table_privilege('authenticated', 'public.notification_events', 'insert') then
    raise exception 'FAIL：authenticated 竟然有 notification_events 的 INSERT grant';
  end if;
  if has_table_privilege('authenticated', 'public.notification_events', 'update') then
    raise exception 'FAIL：authenticated 竟然有 notification_events 的 UPDATE grant';
  end if;
  if has_table_privilege('authenticated', 'public.notification_events', 'delete') then
    raise exception 'FAIL：authenticated 竟然有 notification_events 的 DELETE grant';
  end if;
  if has_table_privilege('anon', 'public.notification_events', 'select') then
    raise exception 'FAIL：anon 竟然有 notification_events 的 SELECT grant';
  end if;
  raise notice 'ok：notification_events 對 authenticated／anon 完全沒有 table grant（SELECT/INSERT/UPDATE/DELETE 皆無）';
end;
$$;

do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;
  begin
    perform count(*) from public.notification_events;
    raise exception 'FAIL：owner 竟然可以直接查詢 notification_events';
  exception when insufficient_privilege then
    null;
  end;
  reset role;
  raise notice 'ok：owner 直接查詢 notification_events 被擋下 (42501)，grant 層先於 RLS 層擋下（PostgREST 到不了 policy）';
end;
$$;

rollback;
