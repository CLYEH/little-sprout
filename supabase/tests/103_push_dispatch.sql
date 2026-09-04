-- LS-172 驗收：public.claim_notification_events()／public.notification_recipients()
-- ——push-dispatch Edge Function 專用的兩支 service_role-only SECURITY DEFINER RPC。
--
-- 情境矩陣（一次交易內建好，逐段用獨立 DO 區塊驗證，最後 rollback 不留痕跡）：
--   家庭 A：owner 爸爸（觸發者／actor）、member 阿嬤（封鎖爸爸）、member 媽媽（兩支
--     裝置）。事件 1：diary，5 分鐘前已穩定（該被 claim）。事件 2：reaction，剛發生
--     （還在 5 分鐘視窗內，不該被 claim）。事件 3：comment，actor_id 為 NULL（模擬
--     觸發者帳號之後被硬刪，FK on delete set null）、已穩定。
--   家庭 B：owner 隔壁家、自己的 device token——只用來驗跨家庭隔離（notification_
--     recipients 絕不能把家庭 A 的 token 洩漏進來，反之亦然）。
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_owner_a uuid := 'd1000000-0000-4000-8000-000000000001'; -- 爸爸（actor）
  v_grandma uuid := 'd1000000-0000-4000-8000-000000000002'; -- 阿嬤（封鎖爸爸）
  v_mom     uuid := 'd1000000-0000-4000-8000-000000000003'; -- 媽媽（兩支裝置，無封鎖）
  v_owner_b uuid := 'd1000000-0000-4000-8000-000000000004'; -- 隔壁家 owner
  v_family_a uuid := 'd2000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'd2000000-0000-4000-8000-000000000002';
  v_event_stable  uuid := 'd3000000-0000-4000-8000-000000000001'; -- 該被 claim
  v_event_fresh   uuid := 'd3000000-0000-4000-8000-000000000002'; -- 5 分鐘內，不該被 claim
  v_event_noactor uuid := 'd3000000-0000-4000-8000-000000000003'; -- actor_id NULL，該被 claim
  v_n int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values
    (v_owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls172-dad@ls172.test', now(), now(), '{}', '{}'),
    (v_grandma, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls172-grandma@ls172.test', now(), now(), '{}', '{}'),
    (v_mom,     '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls172-mom@ls172.test', now(), now(), '{}', '{}'),
    (v_owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls172-other@ls172.test', now(), now(), '{}', '{}');

  update public.profiles set display_name = 'LS172 爸爸'   where id = v_owner_a;
  update public.profiles set display_name = 'LS172 阿嬤'   where id = v_grandma;
  update public.profiles set display_name = 'LS172 媽媽'   where id = v_mom;
  update public.profiles set display_name = 'LS172 隔壁家' where id = v_owner_b;

  insert into public.families (id, name, created_by) values
    (v_family_a, 'LS172 測試家 A', v_owner_a),
    (v_family_b, 'LS172 測試家 B（跨家庭隔離對照）', v_owner_b);

  insert into public.family_members (family_id, user_id, role) values
    (v_family_a, v_owner_a, 'owner'),
    (v_family_a, v_grandma, 'member'),
    (v_family_a, v_mom, 'member')
  on conflict do nothing; -- families 的 AFTER INSERT trigger 已把 owner 自動塞進去

  -- 阿嬤封鎖爸爸（單向、限同家庭）
  insert into public.blocked_users (family_id, blocker_id, blocked_id)
  values (v_family_a, v_grandma, v_owner_a);

  insert into public.device_tokens (token, user_id, platform) values
    ('ls172-tok-grandma', v_grandma, 'ios'),
    ('ls172-tok-mom-1', v_mom, 'ios'),
    ('ls172-tok-mom-2', v_mom, 'ios'),
    ('ls172-tok-dad', v_owner_a, 'ios'),      -- actor 自己的 token：不該出現在自己觸發事件的收件人裡
    ('ls172-tok-other', v_owner_b, 'ios');    -- 家庭 B，跨家庭隔離的對照組

  insert into public.notification_events
    (id, family_id, kind, target_type, target_id, actor_id, event_count, occurred_at)
  values
    (v_event_stable, v_family_a, 'diary', 'diary', 'd4000000-0000-4000-8000-000000000001',
     v_owner_a, 1, now() - interval '10 minutes'),
    (v_event_fresh, v_family_a, 'reaction', 'media', 'd4000000-0000-4000-8000-000000000002',
     v_owner_a, 1, now()),
    (v_event_noactor, v_family_a, 'comment', 'diary', 'd4000000-0000-4000-8000-000000000001',
     null, 1, now() - interval '10 minutes');

  -- -------------------------------------------------------------------------
  -- 1. claim_notification_events：只挑穩定（>5 分鐘）且 sent_at is null 的事件；
  --    5 分鐘內的事件不動；actor_id 為 NULL 的事件 actor_display_name fallback「家人」。
  -- -------------------------------------------------------------------------
  set local role service_role;

  select count(*) into v_n
    from public.claim_notification_events(50)
   where id = v_event_fresh;
  if v_n <> 0 then
    raise exception 'FAIL：5 分鐘內的事件（%）不該被 claim_notification_events 選中', v_event_fresh;
  end if;

  -- 上一句呼叫已經把 v_event_stable／v_event_noactor 一併 claim 走了（同一次呼叫，
  -- p_limit=50 涵蓋全部符合條件的列）——用 sent_at 直接驗證，不用依賴呼叫順序。
  reset role;
  select count(*) into v_n from public.notification_events
   where id in (v_event_stable, v_event_noactor) and sent_at is not null;
  if v_n <> 2 then
    raise exception 'FAIL：v_event_stable／v_event_noactor 應該都已被上一次 claim 呼叫標記 sent_at，實際只有 % 筆', v_n;
  end if;
  select count(*) into v_n from public.notification_events
   where id = v_event_fresh and sent_at is not null;
  if v_n <> 0 then
    raise exception 'FAIL：v_event_fresh（5 分鐘內）不該被標記 sent_at';
  end if;

  raise notice 'ok 1：claim_notification_events 只挑穩定（>5 分鐘）事件，5 分鐘內的事件完全不受影響';

  -- -------------------------------------------------------------------------
  -- 2. claim 兩次不重疊（冪等）：同一批事件已經被上面那次呼叫 claim 走，
  --    再呼叫一次必須是空的——這是「即使已 claim 的送失敗也不回滾 sent_at，
  --    寧可漏送不重送」這個取捨的直接體現（票文明定）。
  -- -------------------------------------------------------------------------
  set local role service_role;
  select count(*) into v_n from public.claim_notification_events(50);
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL：claim_notification_events 第二次呼叫應該是空的（sent_at 已標記），實際回傳 % 筆', v_n;
  end if;
  raise notice 'ok 2：claim 兩次不重疊——第二次呼叫拿到 0 筆';

  -- -------------------------------------------------------------------------
  -- 3. notification_recipients（v_event_stable，actor=爸爸）：
  --    只有媽媽（兩支裝置）；阿嬤被排除（封鎖 actor）；爸爸被排除（actor 本人）；
  --    家庭 B 的 token 絕不能出現（跨家庭隔離）。
  -- -------------------------------------------------------------------------
  set local role service_role;

  select count(*) into v_n from public.notification_recipients(v_event_stable);
  if v_n <> 2 then
    raise exception 'FAIL：v_event_stable 的收件人應該恰好 2 筆（媽媽的兩支裝置），實際 %', v_n;
  end if;

  select count(*) into v_n from public.notification_recipients(v_event_stable)
   where user_id = v_mom;
  if v_n <> 2 then
    raise exception 'FAIL：媽媽的兩支裝置都應該出現在收件人清單，實際 %', v_n;
  end if;

  select count(*) into v_n from public.notification_recipients(v_event_stable)
   where user_id = v_grandma;
  if v_n <> 0 then
    raise exception 'FAIL：阿嬤封鎖了 actor（爸爸），不該出現在收件人清單';
  end if;

  select count(*) into v_n from public.notification_recipients(v_event_stable)
   where user_id = v_owner_a;
  if v_n <> 0 then
    raise exception 'FAIL：actor 本人（爸爸）不該出現在自己觸發事件的收件人清單';
  end if;

  select count(*) into v_n from public.notification_recipients(v_event_stable)
   where token = 'ls172-tok-other';
  if v_n <> 0 then
    raise exception 'FAIL：跨家庭隔離破功——家庭 B 的 token 出現在家庭 A 事件的收件人清單';
  end if;

  raise notice 'ok 3：notification_recipients 對象判定正確——封鎖排除、actor 本人排除、跨家庭隔離、多裝置展開';

  -- -------------------------------------------------------------------------
  -- 4. notification_recipients（v_event_noactor，actor_id=NULL）：
  --    沒有人因為「是 actor 本人」被排除，也沒有人因為「封鎖了 NULL」被排除——
  --    阿嬤（原本封鎖的是爸爸，不是 NULL）與媽媽都應該收到，爸爸自己也該收到
  --    （這則事件的觸發者已經不是他，NULL 不代表他）。
  -- -------------------------------------------------------------------------
  select count(*) into v_n from public.notification_recipients(v_event_noactor);
  if v_n <> 4 then
    raise exception 'FAIL：actor_id 為 NULL 時不該排除任何人，應有 4 筆（爸爸/阿嬤各 1 支 + 媽媽 2 支），實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok 4：actor_id 為 NULL 時，封鎖過濾與「排除 actor 本人」都不誤傷任何人';

  -- -------------------------------------------------------------------------
  -- 5. 無裝置 token 的成員自動略過（用一個全新、沒有任何 device_tokens 的成員驗證）。
  -- -------------------------------------------------------------------------
  declare
    v_no_device uuid := 'd1000000-0000-4000-8000-000000000005';
  begin
    set local role postgres;
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    values (v_no_device, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls172-no-device@ls172.test', now(), now(), '{}', '{}');
    update public.profiles set display_name = 'LS172 沒有裝置' where id = v_no_device;
    insert into public.family_members (family_id, user_id, role) values (v_family_a, v_no_device, 'member');

    set local role service_role;
    select count(*) into v_n from public.notification_recipients(v_event_stable) where user_id = v_no_device;
    reset role;
    if v_n <> 0 then
      raise exception 'FAIL：沒有 device_tokens 的成員不該出現在收件人清單';
    end if;
    raise notice 'ok 5：沒有 device_tokens 的成員自動略過（JOIN 天生排除，不需要額外判斷）';
  end;

  -- -------------------------------------------------------------------------
  -- 6. 授權邊界：authenticated 不能呼叫這兩支函式（42501）；service_role 能（上面
  --    已經實際打過，這裡另外用位元檢查交叉驗證，同 101_purge_expired.sql 既有慣例）。
  -- -------------------------------------------------------------------------
  if not has_function_privilege('service_role', 'public.claim_notification_events(integer)', 'execute') then
    raise exception 'FAIL：service_role 應該對 claim_notification_events() 有 EXECUTE';
  end if;
  if not has_function_privilege('service_role', 'public.notification_recipients(uuid)', 'execute') then
    raise exception 'FAIL：service_role 應該對 notification_recipients() 有 EXECUTE';
  end if;
  if has_function_privilege('authenticated', 'public.claim_notification_events(integer)', 'execute') then
    raise exception 'FAIL：authenticated 不該對 claim_notification_events() 有 EXECUTE';
  end if;
  if has_function_privilege('authenticated', 'public.notification_recipients(uuid)', 'execute') then
    raise exception 'FAIL：authenticated 不該對 notification_recipients() 有 EXECUTE';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_grandma::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.claim_notification_events(10);
    raise exception 'FAIL：authenticated 竟然能呼叫 claim_notification_events()';
  exception when sqlstate '42501' then
    null; -- ok
  end;
  begin
    perform public.notification_recipients(v_event_stable);
    raise exception 'FAIL：authenticated 竟然能呼叫 notification_recipients()';
  exception when sqlstate '42501' then
    null; -- ok
  end;
  reset role;

  raise notice 'ok 6：授權邊界——authenticated 對兩支函式皆無 EXECUTE（位元檢查＋實際呼叫皆驗過），service_role 有';

  -- -------------------------------------------------------------------------
  -- 7. device_tokens 的 service_role grant：SELECT(token) + DELETE 可用；
  --    整表 SELECT／INSERT／UPDATE 不給（見 migration 檔頭第 4 段）；DELETE 真的
  --    生效（不只是位元檢查）。
  -- -------------------------------------------------------------------------
  if not has_table_privilege('service_role', 'public.device_tokens', 'delete') then
    raise exception 'FAIL：service_role 應該對 device_tokens 有 DELETE';
  end if;
  if has_table_privilege('service_role', 'public.device_tokens', 'select') then
    raise exception 'FAIL：service_role 不該對 device_tokens 有整表 SELECT（只開放 token 欄）';
  end if;
  if has_table_privilege('service_role', 'public.device_tokens', 'insert') then
    raise exception 'FAIL：service_role 不該對 device_tokens 有 INSERT';
  end if;

  set local role service_role;
  delete from public.device_tokens where token = 'ls172-tok-dad';
  reset role;
  select count(*) into v_n from public.device_tokens where token = 'ls172-tok-dad';
  if v_n <> 0 then
    raise exception 'FAIL：service_role 對 device_tokens 的 DELETE 沒有真的生效';
  end if;

  raise notice 'ok 7：device_tokens 授權邊界——service_role 可 SELECT(token)／DELETE、不可整表 SELECT／INSERT，且 DELETE 確實生效';
end;
$$;

rollback;
