-- LS-172 驗收：public.claim_notification_events()／public.notification_recipients()
-- ——push-dispatch Edge Function 專用的兩支 service_role-only SECURITY DEFINER RPC。
--
-- 情境矩陣（一次交易內建好，逐段用獨立 DO 區塊驗證，最後 rollback 不留痕跡）：
--   家庭 A：owner 爸爸（觸發者／actor）、member 阿嬤（封鎖爸爸）、member 媽媽（兩支
--     裝置）。事件 1：diary，5 分鐘前已穩定（該被 claim）。事件 2：reaction，剛發生
--     （還在 5 分鐘視窗內，不該被 claim）。事件 3：comment，actor_id 為 NULL（模擬
--     觸發者帳號之後被硬刪，FK on delete set null）、已穩定。事件 4（LS-175）：
--     media／target_type=family，actor 換成媽媽、已穩定——驗 kind='media' 不需要
--     notification_recipients() 任何額外分支即可正確判定對象。
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
  v_viewer  uuid := 'd1000000-0000-4000-8000-000000000006'; -- LS-195：家庭 A viewer（4d 段才加入家庭）
  v_family_a uuid := 'd2000000-0000-4000-8000-000000000001';
  v_family_b uuid := 'd2000000-0000-4000-8000-000000000002';
  v_event_stable  uuid := 'd3000000-0000-4000-8000-000000000001'; -- 該被 claim
  v_event_fresh   uuid := 'd3000000-0000-4000-8000-000000000002'; -- 5 分鐘內，不該被 claim
  v_event_noactor uuid := 'd3000000-0000-4000-8000-000000000003'; -- actor_id NULL，該被 claim
  v_event_media   uuid := 'd3000000-0000-4000-8000-000000000004'; -- LS-175：kind=media，target_type=family
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
     null, 1, now() - interval '10 minutes'),
    -- LS-175：kind='media'／target_type='family'（target_id=家庭自己的 id，見
    -- 20260904170933_media_notification_events.sql 檔頭）——actor 故意選媽媽
    -- （不是上面幾個事件的 actor 爸爸），驗證這個新 kind/target_type 組合不需要
    -- notification_recipients() 任何額外分支就能拿到正確、且與其他事件不同的
    -- 收件人集合（該函式純粹依 family_id／actor_id／blocked_users 判斷，完全
    -- 不看 kind／target_type，見該函式定義）。
    (v_event_media, v_family_a, 'media', 'family', v_family_a,
     v_mom, 50, now() - interval '10 minutes');

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
  -- 3. notification_recipients（batch，array[v_event_stable]，actor=爸爸；
  --    LS-172 R2 改批次簽章 p_event_ids uuid[]）：
  --    只有媽媽（兩支裝置）；阿嬤被排除（封鎖 actor）；爸爸被排除（actor 本人）；
  --    家庭 B 的 token 絕不能出現（跨家庭隔離）。
  -- -------------------------------------------------------------------------
  set local role service_role;

  select count(*) into v_n from public.notification_recipients(array[v_event_stable]);
  if v_n <> 2 then
    raise exception 'FAIL：v_event_stable 的收件人應該恰好 2 筆（媽媽的兩支裝置），實際 %', v_n;
  end if;

  select count(*) into v_n from public.notification_recipients(array[v_event_stable])
   where user_id = v_mom;
  if v_n <> 2 then
    raise exception 'FAIL：媽媽的兩支裝置都應該出現在收件人清單，實際 %', v_n;
  end if;

  select count(*) into v_n from public.notification_recipients(array[v_event_stable])
   where user_id = v_grandma;
  if v_n <> 0 then
    raise exception 'FAIL：阿嬤封鎖了 actor（爸爸），不該出現在收件人清單';
  end if;

  select count(*) into v_n from public.notification_recipients(array[v_event_stable])
   where user_id = v_owner_a;
  if v_n <> 0 then
    raise exception 'FAIL：actor 本人（爸爸）不該出現在自己觸發事件的收件人清單';
  end if;

  select count(*) into v_n from public.notification_recipients(array[v_event_stable])
   where token = 'ls172-tok-other';
  if v_n <> 0 then
    raise exception 'FAIL：跨家庭隔離破功——家庭 B 的 token 出現在家庭 A 事件的收件人清單';
  end if;

  -- 回傳列的 event_id 欄要正確標記成 v_event_stable 本身（不是 NULL、不是別的
  -- event_id）——呼叫端（handler.ts）靠這一欄把收件人分回各自事件，欄位錯了會
  -- 整個分組邏輯壞掉但這裡的 count(*) 斷言完全測不出來。
  select count(*) into v_n from public.notification_recipients(array[v_event_stable])
   where event_id = v_event_stable;
  if v_n <> 2 then
    raise exception 'FAIL：批次呼叫回傳列的 event_id 欄應該標記成 %，實際只有 % 筆對得上', v_event_stable, v_n;
  end if;

  raise notice 'ok 3：notification_recipients 對象判定正確——封鎖排除、actor 本人排除、跨家庭隔離、多裝置展開、event_id 欄正確';

  -- -------------------------------------------------------------------------
  -- 4. notification_recipients（v_event_noactor，actor_id=NULL）：
  --    沒有人因為「是 actor 本人」被排除，也沒有人因為「封鎖了 NULL」被排除——
  --    阿嬤（原本封鎖的是爸爸，不是 NULL）與媽媽都應該收到，爸爸自己也該收到
  --    （這則事件的觸發者已經不是他，NULL 不代表他）。
  -- -------------------------------------------------------------------------
  select count(*) into v_n from public.notification_recipients(array[v_event_noactor]);
  if v_n <> 4 then
    raise exception 'FAIL：actor_id 為 NULL 時不該排除任何人，應有 4 筆（爸爸/阿嬤各 1 支 + 媽媽 2 支），實際 %', v_n;
  end if;
  raise notice 'ok 4：actor_id 為 NULL 時，封鎖過濾與「排除 actor 本人」都不誤傷任何人';

  -- -------------------------------------------------------------------------
  -- 4b. 批次本身：一次呼叫同時帶 v_event_stable 與 v_event_noactor 兩個 event_id
  --     ——回傳列的 event_id 欄要正確把兩批收件人分開（2+4=6 筆），不是誤合併成
  --     同一批、也不是漏掉其中一個事件（LS-172 R2 m1 的核心動機：一次 SQL 呼叫
  --     取整批 claimed 事件的對象）。
  -- -------------------------------------------------------------------------
  select count(*) into v_n
    from public.notification_recipients(array[v_event_stable, v_event_noactor]);
  if v_n <> 6 then
    raise exception 'FAIL：批次同時查兩個事件應該回傳 2+4=6 筆，實際 %（分組可能有洩漏或遺漏）', v_n;
  end if;
  select count(*) into v_n
    from public.notification_recipients(array[v_event_stable, v_event_noactor])
   where event_id = v_event_stable;
  if v_n <> 2 then
    raise exception 'FAIL：批次查詢中 event_id=v_event_stable 的列應該是 2 筆，實際 %', v_n;
  end if;
  select count(*) into v_n
    from public.notification_recipients(array[v_event_stable, v_event_noactor])
   where event_id = v_event_noactor;
  if v_n <> 4 then
    raise exception 'FAIL：批次查詢中 event_id=v_event_noactor 的列應該是 4 筆，實際 %', v_n;
  end if;
  reset role;
  raise notice 'ok 4b：批次同時查兩個事件，收件人正確依 event_id 分組（2+4=6 筆，互不混淆）';

  -- -------------------------------------------------------------------------
  -- 4c.（LS-175）kind='media'／target_type='family' 事件——actor 換成媽媽（不是
  --     其他事件的爸爸），驗證這個新 kind／target_type 組合不需要
  --     notification_recipients() 任何額外分支：只有爸爸與阿嬤該收到（阿嬤沒有
  --     封鎖媽媽，只封鎖爸爸），媽媽自己（actor 本人）被排除。同時驗證這一列
  --     撐過第 1 段的 claim_notification_events() 呼叫（sent_at 已標記）、
  --     kind/target_type/target_id/event_count 四欄沒有因為是新加的列舉值而
  --     寫壞或讀壞。
  -- -------------------------------------------------------------------------
  set local role service_role;

  select count(*) into v_n from public.notification_recipients(array[v_event_media]);
  if v_n <> 2 then
    raise exception 'FAIL：media 事件（actor=媽媽）的收件人應為 2 筆（爸爸 1 支＋阿嬤 1 支，阿嬤只封鎖爸爸不封鎖媽媽），實際 %', v_n;
  end if;
  select count(*) into v_n from public.notification_recipients(array[v_event_media])
   where user_id = v_owner_a;
  if v_n <> 1 then
    raise exception 'FAIL：爸爸應該收到媽媽觸發的 media 事件，實際 %', v_n;
  end if;
  select count(*) into v_n from public.notification_recipients(array[v_event_media])
   where user_id = v_grandma;
  if v_n <> 1 then
    raise exception 'FAIL：阿嬤沒有封鎖媽媽，應該收到媽媽觸發的 media 事件，實際 %', v_n;
  end if;
  select count(*) into v_n from public.notification_recipients(array[v_event_media])
   where user_id = v_mom;
  if v_n <> 0 then
    raise exception 'FAIL：actor 本人（媽媽）不該出現在自己觸發的 media 事件收件人清單';
  end if;

  -- v_event_media 在最上面第 1 段的第一次 claim_notification_events(50) 呼叫時
  -- 就已經跟 v_event_stable／v_event_noactor 一起被 claim 走了（同一句 SQL，沒有
  -- kind 篩選）——這裡改直接查表確認它撐過那次 claim（sent_at 已標記）且欄位
  -- 沒有因為是新加的列舉值而寫壞／讀壞，不是重新呼叫 claim_notification_events
  -- 拿 0 筆去誤判失敗。
  reset role;
  select count(*) into v_n from public.notification_events
   where id = v_event_media and kind = 'media' and target_type = 'family'
     and target_id = v_family_a and event_count = 50 and sent_at is not null;
  if v_n <> 1 then
    raise exception 'FAIL：v_event_media 應該已被第 1 段的 claim_notification_events 呼叫標記 sent_at，且 kind/target_type/target_id/event_count 四欄原樣保留，實際符合條件的筆數 %', v_n;
  end if;
  raise notice 'ok 4c：kind=media／target_type=family 事件不需要 notification_recipients() 任何額外分支，對象判定正確（爸爸/阿嬤收到、媽媽本人排除）；claim_notification_events 正確 round-trip 新列舉值';

  -- -------------------------------------------------------------------------
  -- 4d.（LS-195）kind='report' 只通知家庭 owner，不廣播給其餘成員／viewer；其餘
  --     kind 不受影響。這裡才把 viewer（v_viewer）加入家庭 A——刻意晚於前面
  --     1～4c 段所有依賴「家庭 A 只有 owner_a／grandma／mom 三人」的既有計數斷言
  --     （procedural DO 區塊依序執行，viewer 加入前那些 SELECT 早就跑完，不受影響）。
  -- -------------------------------------------------------------------------
  declare
    v_event_report       uuid := 'd3000000-0000-4000-8000-000000000005'; -- kind=report，actor=阿嬤（member）
    v_event_report_owner uuid := 'd3000000-0000-4000-8000-000000000006'; -- kind=report，actor=爸爸自己（owner 自報）
    v_event_album        uuid := 'd3000000-0000-4000-8000-000000000007'; -- 對照組：非 report kind，驗 viewer 仍在全員名單
  begin
    set local role postgres;
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
    values (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls195-viewer@ls172.test', now(), now(), '{}', '{}');
    update public.profiles set display_name = 'LS195 viewer' where id = v_viewer;
    insert into public.family_members (family_id, user_id, role) values (v_family_a, v_viewer, 'viewer');
    insert into public.device_tokens (token, user_id, platform) values ('ls195-tok-viewer', v_viewer, 'ios');

    insert into public.notification_events (id, family_id, kind, target_type, target_id, actor_id, event_count, occurred_at)
    values
      (v_event_report, v_family_a, 'report', 'diary', 'd4000000-0000-4000-8000-000000000001',
       v_grandma, 1, now() - interval '10 minutes'),
      (v_event_report_owner, v_family_a, 'report', 'diary', 'd4000000-0000-4000-8000-000000000001',
       v_owner_a, 1, now() - interval '10 minutes'),
      (v_event_album, v_family_a, 'album', 'album', 'd4000000-0000-4000-8000-000000000005',
       null, 1, now() - interval '10 minutes');

    set local role service_role;

    -- report、actor=阿嬤：只有爸爸（owner）該收到；媽媽（member）、viewer、阿嬤本人都不該收到
    select count(*) into v_n from public.notification_recipients(array[v_event_report]);
    if v_n <> 1 then
      raise exception 'FAIL：report 事件的收件人應該恰好 1 筆（爸爸，owner），實際 %', v_n;
    end if;
    select count(*) into v_n from public.notification_recipients(array[v_event_report]) where user_id = v_owner_a;
    if v_n <> 1 then
      raise exception 'FAIL：爸爸（owner）應該收到 report 事件通知';
    end if;
    select count(*) into v_n from public.notification_recipients(array[v_event_report]) where user_id = v_mom;
    if v_n <> 0 then
      raise exception 'FAIL：媽媽（member，非 owner）不該收到 report 事件通知';
    end if;
    select count(*) into v_n from public.notification_recipients(array[v_event_report]) where user_id = v_viewer;
    if v_n <> 0 then
      raise exception 'FAIL：viewer 不該收到 report 事件通知';
    end if;
    select count(*) into v_n from public.notification_recipients(array[v_event_report]) where user_id = v_grandma;
    if v_n <> 0 then
      raise exception 'FAIL：阿嬤是這則 report 的 actor 本人，不該收到自己的通知';
    end if;

    -- report、actor=爸爸自己（owner 自報）：家裡唯一的 owner 就是 actor 本人 → 0 列
    select count(*) into v_n from public.notification_recipients(array[v_event_report_owner]);
    if v_n <> 0 then
      raise exception 'FAIL：owner 自己是 report 的 actor 時，收件人應為 0 筆，實際 %', v_n;
    end if;

    -- 對照組：非 report kind（album，actor=NULL）不受這次收窄影響——爸爸(1)/阿嬤(1)/
    -- 媽媽(2)/viewer(1) 共 5 支裝置，viewer 加入家庭之後一樣在全員名單裡
    select count(*) into v_n from public.notification_recipients(array[v_event_album]);
    if v_n <> 5 then
      raise exception 'FAIL：非 report kind 不該被本票的新條件影響，應回全家庭 5 支裝置（爸爸1/阿嬤1/媽媽2/viewer1），實際 %', v_n;
    end if;
    select count(*) into v_n from public.notification_recipients(array[v_event_album]) where user_id = v_viewer;
    if v_n <> 1 then
      raise exception 'FAIL：viewer 應該照樣收到非 report kind 的通知（本票只收窄 report，不影響其他 kind）';
    end if;

    reset role;
  end;
  raise notice 'ok 4d：kind=report 只留 family_members.role=owner（LS-195）——member／viewer／actor 本人皆排除，owner 自報時 0 列；非 report kind 不受影響、viewer 仍在全員名單';

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
    select count(*) into v_n from public.notification_recipients(array[v_event_stable]) where user_id = v_no_device;
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
  if not has_function_privilege('service_role', 'public.notification_recipients(uuid[])', 'execute') then
    raise exception 'FAIL：service_role 應該對 notification_recipients() 有 EXECUTE';
  end if;
  if has_function_privilege('authenticated', 'public.claim_notification_events(integer)', 'execute') then
    raise exception 'FAIL：authenticated 不該對 claim_notification_events() 有 EXECUTE';
  end if;
  if has_function_privilege('authenticated', 'public.notification_recipients(uuid[])', 'execute') then
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
    perform public.notification_recipients(array[v_event_stable]);
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
