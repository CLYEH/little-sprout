-- LS-175（LS-22 後端切片）— media AFTER INSERT trigger 進 notification_events 驗收
--
-- 對應三支 migration：
--   20260904170849_media_notification_target_family.sql（content_target_type
--     加值 'family'）／20260904170920_media_notification_kind.sql
--     （notification_kind 加值 'media'）／20260904170933_media_notification_
--     events.sql（private.notify_media_created() trigger）。
--
-- 情境矩陣（一次交易內建好，逐段用獨立 DO 區塊驗證，最後 rollback 不留痕跡——
-- 全程只在交易內插入列，不建任何輔助表，收工不留殘渣，同 run.sh 既有慣例）：
--   用全新的測試家庭，不沿用 00_fixtures.sql 的 A/B 家——那兩個家庭在 fixtures
--   階段就已經各自因為既有的媒體列觸發過一次 media 事件（`00_fixtures.sql` 用
--   一句多列 INSERT 同時灌 A 家 2 張、B 家 1 張），若沿用會讓 event_count 的
--   斷言依賴 fixtures 的內部細節；全新家庭讓每個情境的起始狀態是乾淨的 0。
--   家庭 M：owner 爸爸、member 媽媽——驗基本彙總／5 分鐘視窗累加／軟刪不觸發／
--     INSERT 當下已軟刪不觸發。
--   家庭 N：owner 阿公——只用來驗跨家庭隔離、以及單一 INSERT 敘述橫跨兩個家庭時
--     transition table 的 GROUP BY 正確分家。
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_dad uuid := 'e1000000-0000-4000-8000-000000000001';
  v_mom uuid := 'e1000000-0000-4000-8000-000000000002';
  v_grandpa uuid := 'e1000000-0000-4000-8000-000000000003';
  v_family_m uuid := 'e2000000-0000-4000-8000-000000000001';
  v_family_n uuid := 'e2000000-0000-4000-8000-000000000002';
  v_n int;
  v_event_id uuid;
  v_event_id2 uuid;
  v_event_count int;
  v_target_type public.content_target_type;
  v_target_id uuid;
  v_actor uuid;
  i int;
begin
  set local role postgres;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values
    (v_dad, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls175-dad@ls175.test', now(), now(), '{}', '{}'),
    (v_mom, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls175-mom@ls175.test', now(), now(), '{}', '{}'),
    (v_grandpa, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ls175-grandpa@ls175.test', now(), now(), '{}', '{}');

  update public.profiles set display_name = 'LS175 爸爸' where id = v_dad;
  update public.profiles set display_name = 'LS175 媽媽' where id = v_mom;
  update public.profiles set display_name = 'LS175 阿公' where id = v_grandpa;

  insert into public.families (id, name, created_by) values
    (v_family_m, 'LS175 測試家 M', v_dad),
    (v_family_n, 'LS175 測試家 N（跨家庭隔離對照）', v_grandpa);

  -- families 的 AFTER INSERT trigger（private.add_creator_as_owner）已經把
  -- v_dad／v_grandpa 各自塞進自己家的 family_members；這裡只補媽媽。
  insert into public.family_members (family_id, user_id, role) values
    (v_family_m, v_mom, 'member');

  -- -------------------------------------------------------------------------
  -- 1.（票文驗收 1）50 張一批——50 次各自獨立的單列 INSERT，貼近真實 client
  --    行為（`MediaUploadService.uploadPhoto` 每張照片各自一次 `.insert()`，
  --    不是一次多列 INSERT）→ 應合併成恰 1 筆事件，event_count=50，
  --    kind='media'，target_type='family'，target_id=家庭自己的 id。
  -- -------------------------------------------------------------------------
  for i in 1..50 loop
    insert into public.media
      (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values
      (v_family_m,
       v_family_m::text || '/2026/09/' || gen_random_uuid()::text || '.jpg',
       'photo', 1024, 100, 100, v_dad);
  end loop;

  select count(*) into v_n from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_n <> 1 then
    raise exception 'FAIL：家庭 M 50 張批次上傳（50 次各自獨立 INSERT）後應恰好 1 筆 kind=media 事件，實際 % 筆', v_n;
  end if;

  select id, event_count, target_type, target_id, actor_id
    into v_event_id, v_event_count, v_target_type, v_target_id, v_actor
    from public.notification_events
   where family_id = v_family_m and kind = 'media';

  if v_event_count <> 50 then
    raise exception 'FAIL：event_count 應為 50，實際 %', v_event_count;
  end if;
  if v_target_type <> 'family' then
    raise exception 'FAIL：target_type 應為 ''family''，實際 %', v_target_type;
  end if;
  if v_target_id <> v_family_m then
    raise exception 'FAIL：target_id 應等於 family_id 本身（%），實際 %', v_family_m, v_target_id;
  end if;
  if v_actor <> v_dad then
    raise exception 'FAIL：actor_id 應為觸發者（爸爸，這 50 張全是他上傳的），實際 %', v_actor;
  end if;

  raise notice 'ok 1：50 張一批（50 次各自獨立 INSERT）彙總成恰 1 筆事件，event_count=50，target_type=family，target_id=family_id，actor_id=爸爸';

  -- -------------------------------------------------------------------------
  -- 2.（票文驗收 2）5 分鐘內第二批（媽媽再傳 10 張）→ 同一列累加，不是新開一筆
  --    ——沿用既有 5 分鐘滾動視窗＋advisory lock（private.record_notification_
  --    event），這裡不重新驗那個機制本身（87_ 已經驗過），只驗 media trigger
  --    正確接上它。
  -- -------------------------------------------------------------------------
  for i in 1..10 loop
    insert into public.media
      (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values
      (v_family_m,
       v_family_m::text || '/2026/09/' || gen_random_uuid()::text || '.jpg',
       'photo', 2048, 100, 100, v_mom);
  end loop;

  select count(*) into v_n from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_n <> 1 then
    raise exception 'FAIL：5 分鐘內第二批應該合併進同一筆事件，實際變成 % 筆', v_n;
  end if;

  select id, event_count, actor_id into v_event_id2, v_event_count, v_actor
    from public.notification_events
   where family_id = v_family_m and kind = 'media';

  if v_event_id2 <> v_event_id then
    raise exception 'FAIL：合併應沿用同一筆事件 id（%），實際變成新的一筆（%）', v_event_id, v_event_id2;
  end if;
  if v_event_count <> 60 then
    raise exception 'FAIL：event_count 應累加到 60（50+10），實際 %', v_event_count;
  end if;
  if v_actor <> v_mom then
    raise exception 'FAIL：actor_id 應換成最新觸發者（媽媽），實際 %', v_actor;
  end if;

  raise notice 'ok 2：5 分鐘內第二批（10 張）合併進同一筆事件（沿用同一 id），event_count 累加為 60，actor_id 換成最新觸發者';

  -- -------------------------------------------------------------------------
  -- 3.（票文驗收 4）軟刪不觸發——UPDATE deleted_at 不是 INSERT，AFTER INSERT
  --    trigger 本來就不會被 UPDATE 觸發，這裡明確斷言一次：不新增事件、不改動
  --    既有 event_count。
  -- -------------------------------------------------------------------------
  update public.media set deleted_at = now()
   where id = (select id from public.media where family_id = v_family_m and deleted_at is null limit 1);

  select count(*) into v_n from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_n <> 1 then
    raise exception 'FAIL：軟刪一張照片不該新增事件，仍應恰好 1 筆，實際 %', v_n;
  end if;
  select event_count into v_event_count from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_event_count <> 60 then
    raise exception 'FAIL：軟刪不該改動既有 event_count，應維持 60，實際 %', v_event_count;
  end if;

  raise notice 'ok 3：軟刪（UPDATE deleted_at）不觸發通知，事件筆數與 event_count 皆不受影響';

  -- -------------------------------------------------------------------------
  -- 4. INSERT 當下 deleted_at 就已非 NULL（防禦性邊界——media 對 authenticated
  --    的 INSERT grant 是整表授權，理論上可以夾帶這欄一起寫入，見 migration
  --    檔頭）→ trigger 的 WHERE deleted_at is null 要把這種列排除在分組之外，
  --    不計入通知。
  -- -------------------------------------------------------------------------
  insert into public.media
    (family_id, storage_path, type, byte_size, width, height, uploaded_by, deleted_at)
  values
    (v_family_m,
     v_family_m::text || '/2026/09/' || gen_random_uuid()::text || '.jpg',
     'photo', 4096, 100, 100, v_dad, now());

  select event_count into v_event_count from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_event_count <> 60 then
    raise exception 'FAIL：INSERT 當下已軟刪的列不該被計入通知，event_count 應維持 60，實際 %', v_event_count;
  end if;
  select count(*) into v_n from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_n <> 1 then
    raise exception 'FAIL：INSERT 當下已軟刪的列也不該另開一筆事件，仍應恰好 1 筆，實際 %', v_n;
  end if;

  raise notice 'ok 4：INSERT 當下 deleted_at 已非 NULL 的列被 trigger 排除，不計入任何事件';

  -- -------------------------------------------------------------------------
  -- 5.（票文驗收 3）跨家庭隔離——家庭 N 自己的批次（5 張）不該影響家庭 M 的
  --    事件，也要各自產生自己的一筆。
  -- -------------------------------------------------------------------------
  for i in 1..5 loop
    insert into public.media
      (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values
      (v_family_n,
       v_family_n::text || '/2026/09/' || gen_random_uuid()::text || '.jpg',
       'photo', 1024, 100, 100, v_grandpa);
  end loop;

  select count(*) into v_n from public.notification_events
   where family_id = v_family_n and kind = 'media';
  if v_n <> 1 then
    raise exception 'FAIL：家庭 N 5 張批次上傳後應恰好 1 筆事件，實際 %', v_n;
  end if;
  select event_count, target_id into v_event_count, v_target_id
    from public.notification_events where family_id = v_family_n and kind = 'media';
  if v_event_count <> 5 then
    raise exception 'FAIL：家庭 N 的 event_count 應為 5，實際 %', v_event_count;
  end if;
  if v_target_id <> v_family_n then
    raise exception 'FAIL：家庭 N 的 target_id 應等於家庭 N 自己的 id，實際 %', v_target_id;
  end if;

  -- 家庭 M 的既有事件必須完全不受影響（跨家庭隔離的另一半）。
  select event_count into v_event_count from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_event_count <> 60 then
    raise exception 'FAIL：家庭 N 的批次不該影響家庭 M 的 event_count（應仍是 60），實際 %', v_event_count;
  end if;

  raise notice 'ok 5：跨家庭隔離——家庭 N 自己開一筆事件（event_count=5，target_id=家庭 N），完全不影響家庭 M 既有的事件';

  -- -------------------------------------------------------------------------
  -- 6. 單一 INSERT 敘述橫跨兩個家庭（一次多列 VALUES，同 00_fixtures.sql 的
  --    既有寫法）→ statement-level trigger 的 REFERENCING NEW TABLE 一次觸發，
  --    trigger 內的 GROUP BY family_id 要正確分成兩組、各自累加進各自家庭的
  --    既有事件，不會混在一起、也不會漏掉其中一個家庭（防禦性：目前實際的
  --    client 寫入路徑恆為單列 INSERT，這裡驗的是 trigger 本身的形狀在真的
  --    出現批次 INSERT 時仍然正確）。
  -- -------------------------------------------------------------------------
  insert into public.media
    (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values
    (v_family_m, v_family_m::text || '/2026/09/' || gen_random_uuid()::text || '.jpg', 'photo', 1024, 100, 100, v_dad),
    (v_family_n, v_family_n::text || '/2026/09/' || gen_random_uuid()::text || '.jpg', 'photo', 1024, 100, 100, v_grandpa);

  select count(*) into v_n from public.notification_events where kind = 'media'
   and family_id in (v_family_m, v_family_n);
  if v_n <> 2 then
    raise exception 'FAIL：單一敘述橫跨兩家後，兩個家庭應該各自仍是 1 筆（共 2 筆），實際 %', v_n;
  end if;
  select event_count into v_event_count from public.notification_events
   where family_id = v_family_m and kind = 'media';
  if v_event_count <> 61 then
    raise exception 'FAIL：家庭 M 應累加為 61（60+1），實際 %', v_event_count;
  end if;
  select event_count into v_event_count from public.notification_events
   where family_id = v_family_n and kind = 'media';
  if v_event_count <> 6 then
    raise exception 'FAIL：家庭 N 應累加為 6（5+1），實際 %', v_event_count;
  end if;

  raise notice 'ok 6：單一 INSERT 敘述橫跨兩個家庭，transition table 的 GROUP BY 正確分家（家庭 M→61、家庭 N→6），沒有混淆也沒有遺漏';

  -- -------------------------------------------------------------------------
  -- 7. 授權邊界：authenticated 不能直接呼叫 private.notify_media_created()
  --    （42501，沒有 EXECUTE——同既有四支 notify_* trigger 函式的既有慣例，
  --    見 87_comments_reactions_notifications.sql §8）。
  -- -------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_mom::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform private.notify_media_created();
    raise exception 'FAIL：authenticated 竟然能直呼 private.notify_media_created()（授權邊界形同虛設）';
  exception when sqlstate '42501' then
    null; -- ok
  end;
  reset role;

  raise notice 'ok 7：authenticated 直呼 private.notify_media_created() 卡在 42501（沒有 EXECUTE 授權，同既有四支 notify_* trigger 函式）';
end;
$$;

rollback;
