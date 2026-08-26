-- LS-110 — profiles 由 auth.users insert trigger 自動建立＋回填
--
-- 對應 20260826005443_profiles_auto_create_trigger.sql。除第 7 段外，各段各自
-- begin/rollback，互不污染，也不影響 00_fixtures.sql 建好的共用資料：
--   1-4：display_name／avatar_url 推導（full_name 優先、退回 name、都沒有時退回
--        email 帳號部分、avatar_url 一併帶入）
--   5：trigger 建立列之後，呼叫端（LS-107 ensureProfileExists／既有 fixture 慣例）
--      再冪等 insert 一次不會撞 23505，也不會覆蓋 trigger 已推導出的值
--   6：回填語句本身冪等——模擬「trigger 佈署前就存在的 auth.users 缺列」，跑一次
--      回填補上，再跑一次驗證不噴錯、不產生第二列
--   7：結構性斷言（R1 F2）——不靠「postgres 身分能跑」推論安全，直接查
--      private.handle_new_auth_user() 是 SECURITY DEFINER、owner 對 profiles 有
--      INSERT、trigger 未被停用；純讀 catalog，不需要交易保護
--   8-11：display_name 正規化邊界值（R1 F1）——超長截斷、full_name 空字串視同沒有
--        （退回 name）、full_name 全空白且無 name 時退回 email 帳號部分、email 與
--        metadata 都落空時保底 '新成員'。「full_name 缺但 name 在」已由第 2 段覆蓋，
--        這裡不重複
--
-- 正式路徑角色（supabase_auth_admin）探針另外放在 auth_admin/
-- profiles_trigger_probe_insert.sql／_verify.sql（R1 F2）——需要換連線身分，不能
-- 用本檔案共用的 postgres 連線跑，見該兩檔與 supabase/tests/run.sh 的
-- run_sql_as_auth_admin。

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. display_name 推導：full_name 優先於 name
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-fullname@ls110.test', now(), now(), '{}',
        '{"full_name": "有全名的人", "name": "備援名字"}');

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000001';

  if v_name is null then
    raise exception 'FAIL：auth.users insert 後 profiles 沒有自動建立';
  end if;
  if v_name <> '有全名的人' then
    raise exception 'FAIL：display_name 推導順序錯誤，full_name 應優先於 name（實際「%」）', v_name;
  end if;
  raise notice 'ok：full_name 優先，profiles 自動建立（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 2. display_name 推導：沒有 full_name 時退回 name
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-name@ls110.test', now(), now(), '{}',
        '{"name": "只有 name 的人"}');

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000002';
  if v_name <> '只有 name 的人' then
    raise exception 'FAIL：沒有 full_name 時應退回 name（實際「%」）', v_name;
  end if;
  raise notice 'ok：退回 name（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 3. display_name 推導：都沒有時退回 email 帳號部分；avatar_url 無值時為 NULL
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-bare@ls110.test', now(), now(), '{}', '{}');

do $$
declare
  v_name text;
  v_avatar text;
begin
  select display_name, avatar_url into v_name, v_avatar from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000003';
  if v_name <> 'ls110-bare' then
    raise exception 'FAIL：都沒有 metadata 時應退回 email 帳號部分（實際「%」）', v_name;
  end if;
  if v_avatar is not null then
    raise exception 'FAIL：沒有 avatar_url metadata 時應為 NULL（實際「%」）', v_avatar;
  end if;
  raise notice 'ok：退回 email 帳號部分（display_name=%），avatar_url 無值時為 NULL', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 4. avatar_url 一併帶入
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-avatar@ls110.test', now(), now(), '{}',
        '{"full_name": "有頭像的人", "avatar_url": "https://example.test/a.png"}');

do $$
declare
  v_avatar text;
begin
  select avatar_url into v_avatar from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000004';
  if v_avatar <> 'https://example.test/a.png' then
    raise exception 'FAIL：avatar_url 沒有正確帶入（實際「%」）', v_avatar;
  end if;
  raise notice 'ok：avatar_url 正確帶入（%）', v_avatar;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 5. 重複 insert 不炸：trigger 已建好列之後，呼叫端／fixture 慣例的冪等 insert
--    不應撞 23505，也不應蓋掉 trigger 推導出的值
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-dup@ls110.test', now(), now(), '{}',
        '{"full_name": "重複測試"}');

-- 呼叫端慣例（LS-107 ensureProfileExists／既有 supabase/tests fixture 寫法）：
-- 明知列可能已存在，仍冪等地再 insert 一次
insert into public.profiles (id, display_name)
values ('f1000000-0000-4000-8000-000000000005', '呼叫端想蓋掉的名字')
on conflict (id) do nothing;

do $$
declare
  v_name text;
  v_count int;
begin
  select count(*) into v_count from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000005';
  if v_count <> 1 then
    raise exception 'FAIL：重複 insert 後 profiles 應恰好 1 列（實際 %）', v_count;
  end if;

  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000005';
  if v_name <> '重複測試' then
    raise exception 'FAIL：on conflict do nothing 不該被呼叫端的重複 insert 蓋掉（實際「%」）', v_name;
  end if;
  raise notice 'ok：trigger 建立列後重複 insert 不炸，且不覆蓋既有值（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 6. 回填冪等：模擬「auth.users 存在但缺對應 profiles 列」——這正是回填語句要
--    處理的情境（不論缺列原因是帳號建立於 trigger 佈署之前，或列被其他方式清掉，
--    對回填語句而言是同一種局面：auth.users 有、profiles 沒有）。
--
--    這裡刻意不用「暫時 disable trigger 再 insert auth.users」來重現缺列：
--    ALTER TABLE ... DISABLE TRIGGER 需要 auth.users 的 table owner 權限，
--    本機／CI 的 migration 執行身分（postgres）只被 grant 了 TRIGGER 權限（因此建得
--    了 trigger），並不是 auth.users 的 owner（實測：跑下去直接 42501「must be owner
--    of table users」）。改用「trigger 先正常建立列，再 DELETE 掉」模擬缺列，
--    效果等價且不需要額外權限。
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000006', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-backfill@ls110.test', now(), now(), '{}',
        '{"full_name": "補回填的人"}');

-- trigger 已經自動建了一列；刪掉它來模擬「auth.users 存在、profiles 缺列」。
delete from public.profiles where id = 'f1000000-0000-4000-8000-000000000006';

do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000006';
  if v_count <> 0 then
    raise exception 'FAIL：模擬缺列失敗，profiles 仍然存在（回填情境的前提假設本身就錯）';
  end if;
end;
$$;

-- 與 migration 同形狀的回填語句（見 20260826005443_profiles_auto_create_trigger.sql）
insert into public.profiles (id, display_name, avatar_url)
select u.id,
       coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name',
                split_part(u.email, '@', 1)),
       u.raw_user_meta_data ->> 'avatar_url'
  from auth.users u
 where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000006';
  if v_name <> '補回填的人' then
    raise exception 'FAIL：回填語句沒有正確補上缺列（實際「%」）', v_name;
  end if;
  raise notice 'ok：回填語句補上 trigger 佈署前遺留的缺列（display_name=%）', v_name;
end;
$$;

-- 再跑一次同一句回填語句：必須冪等（不噴錯、不新增第二列）
insert into public.profiles (id, display_name, avatar_url)
select u.id,
       coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name',
                split_part(u.email, '@', 1)),
       u.raw_user_meta_data ->> 'avatar_url'
  from auth.users u
 where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

do $$
declare
  v_count int;
begin
  select count(*) into v_count from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000006';
  if v_count <> 1 then
    raise exception 'FAIL：回填語句重跑後應仍是 1 列（實際 %）——回填不冪等', v_count;
  end if;
  raise notice 'ok：回填語句重跑後仍是 1 列，冪等成立';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 7. 結構性斷言（R1 F2）：前六段都是以本檔案執行者（本機／CI 一般是 postgres）
--    身分驗證「trigger 能跑」，這件事本身不是保證——若函式哪天被改成
--    SECURITY INVOKER、owner 換人、或 trigger 被停用，前六段仍會全綠，紅燈只會
--    出現在正式站的 GoTrue 500。這裡直接查 catalog，把三個前提釘住。純讀，不
--    需要交易保護。
-- ---------------------------------------------------------------------------
do $$
declare
  v_prosecdef boolean;
  v_owner_has_insert boolean;
  v_tgenabled "char";
begin
  select p.prosecdef into v_prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'handle_new_auth_user';
  if v_prosecdef is not true then
    raise exception 'FAIL：private.handle_new_auth_user() 必須是 SECURITY DEFINER（prosecdef=true），實際 %', v_prosecdef;
  end if;

  select has_table_privilege(p.proowner, 'public.profiles', 'INSERT') into v_owner_has_insert
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'handle_new_auth_user';
  if v_owner_has_insert is not true then
    raise exception 'FAIL：private.handle_new_auth_user() 的 owner 對 public.profiles 沒有 INSERT 權限';
  end if;

  select t.tgenabled into v_tgenabled
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'auth' and c.relname = 'users' and t.tgname = 'on_auth_user_created';
  if v_tgenabled is null then
    raise exception 'FAIL：找不到 auth.users 上的 on_auth_user_created trigger';
  end if;
  if v_tgenabled = 'D' then
    raise exception 'FAIL：on_auth_user_created trigger 被停用（tgenabled=D）';
  end if;

  raise notice 'ok：函式 SECURITY DEFINER、owner 對 profiles 有 INSERT、trigger 未停用（tgenabled=%）', v_tgenabled;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. display_name 正規化（R1 F1）：超長 full_name 必須被截斷到 50 字，而不是讓
--    profiles_display_name_check 炸掉整個 auth.users 的 INSERT 交易
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000007', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-toolong@ls110.test', now(), now(), '{}',
        jsonb_build_object('full_name', repeat('威', 80)));

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000007';
  if char_length(v_name) < 1 or char_length(v_name) > 50 then
    raise exception 'FAIL：超長 display_name 沒有被截斷到 1~50 字（實際長度 %）', char_length(v_name);
  end if;
  if v_name <> left(repeat('威', 80), 50) then
    raise exception 'FAIL：超長 display_name 截斷內容不對（實際「%」）', v_name;
  end if;
  raise notice 'ok：超長 display_name 截斷為 50 字（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 9. display_name 正規化（R1 F1）：full_name 是空字串時要視同沒有這個候選、退回
--    name，而不是把空字串直接塞進 profiles_display_name_check（->> 對空字串回傳
--    的是長度 0 的字串，不是 NULL，coalesce 本身不會跳過）
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000008', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-emptyfull@ls110.test', now(), now(), '{}',
        '{"full_name": "", "name": "空字串退回測試"}');

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000008';
  if v_name <> '空字串退回測試' then
    raise exception 'FAIL：full_name 是空字串時應視同沒有、退回 name（實際「%」）', v_name;
  end if;
  raise notice 'ok：full_name 空字串正確視同沒有，退回 name（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 10. display_name 正規化（R1 F1）：full_name 全是空白字元、且沒有 name 時，要
--     退回 email 帳號部分，而不是把全空白字串塞進 check constraint
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-000000000009', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ls110-blank@ls110.test', now(), now(), '{}',
        '{"full_name": "   "}');

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-000000000009';
  if v_name <> 'ls110-blank' then
    raise exception 'FAIL：full_name 全是空白時應視同沒有、退回 email 帳號部分（實際「%」）', v_name;
  end if;
  raise notice 'ok：全空白 full_name 正確視同沒有，退回 email 帳號部分（display_name=%）', v_name;
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 11. display_name 正規化（R1 F1）：email 也是 NULL（anon 使用者的形狀，目前
--     config.toml 的 enable_anonymous_sign_ins=false 擋著，但這是設定擋、不是
--     schema 擋，函式本身要對這個輸入形狀負責）且 metadata 沒有任何候選時，
--     最終保底 '新成員'，不能讓 not-null 違反把整個 auth.users 的 INSERT 交易
--     rollback
-- ---------------------------------------------------------------------------
begin;

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('f1000000-0000-4000-8000-00000000000a', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', null, now(), now(), '{}', '{}');

do $$
declare
  v_name text;
begin
  select display_name into v_name from public.profiles
   where id = 'f1000000-0000-4000-8000-00000000000a';
  if v_name <> '新成員' then
    raise exception 'FAIL：email 與 metadata 都沒有候選值時應保底為新成員（實際「%」）', v_name;
  end if;
  raise notice 'ok：三個候選都落空時保底為新成員（display_name=%）', v_name;
end;
$$;

rollback;
