-- LS-134（LS-20 後端）— media 影片時長欄：duration_seconds
--
-- 對應 20260902195055_media_duration_seconds.sql 的四段自證：
--   1. 欄位存在＋nullable（information_schema）
--   2. CHECK 正負案例（duration_seconds > 0）
--   3. RLS 跨家庭不可讀（既有 media_select policy 是 row-level，新欄位不需要另外
--      開洞）
--   4. duration_seconds 一旦 INSERT 即不可 UPDATE（比照 storage_path／thumb_path
--      的既有慣例）
--
-- 不驗「type='video' 必填 duration_seconds」：這條相依關係是上傳端契約義務
-- （docs/API.md §3），不是資料庫可以機械驗證的不變量（見 migration 檔頭）——本檔
-- 第 2 段刻意示範 type='video' 且 duration_seconds 為 NULL 仍可插入成功，避免日後
-- 有人誤把這裡的『成功』案例當成漏測而補一條 DB 沒有、也不該有的 CHECK。
--
-- 不驗 RPC：get_family_timeline 只回傳 kind/ref_id/occurred_at/child_id 這組最小
-- 指標集合，從未回傳過 media 的任何欄位（docs/API.md §4）；duration_seconds 的實際
-- 讀取由呼叫端直接查 public.media（RLS 已保護）取得，不經過這支 RPC，因此本票不改
-- 任何 RPC 簽章或回傳型別，這裡也不需要對應測試——決定記在 migration 檔頭與 PR
-- body。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 欄位存在＋nullable
-- ===========================================================================
do $$
declare
  v_col record;
begin
  select column_name, is_nullable, data_type into v_col
    from information_schema.columns
   where table_schema = 'public' and table_name = 'media' and column_name = 'duration_seconds';

  if v_col.column_name is null then
    raise exception 'FAIL：public.media 缺少欄位 duration_seconds';
  end if;
  if v_col.is_nullable <> 'YES' then
    raise exception 'FAIL：public.media.duration_seconds 不是 nullable（is_nullable=%）', v_col.is_nullable;
  end if;
  if v_col.data_type <> 'integer' then
    raise exception 'FAIL：public.media.duration_seconds 型別不是 integer（data_type=%）', v_col.data_type;
  end if;

  raise notice 'ok：duration_seconds 欄位存在、nullable、型別 integer';
end;
$$;

-- ===========================================================================
-- 2. CHECK 正負案例
--
-- 全部以 A 家 owner 身分（有上傳權，INSERT policy 會放行），驗證的是欄位本身的
-- CHECK，不是 RLS——每個負案例只改一個變數，其餘維持合法值，這樣「拿掉
-- media_duration_seconds_positive」時對應的那一個案例會從『擋下』變成『插入成功』
-- 而讓測試變紅，具備鑑別力（PR body 的 mutation 清單逐條對應本段）。
-- ===========================================================================
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  -- 正案例：影片、duration_seconds 為正整數 —— 必須成功
  insert into public.media
    (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
     duration_seconds)
  values
    ('3b000000-0000-4000-8000-0000000000d1', 'fa000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d1.mp4',
     'video', 4096, 1080, 1920, 'a0000000-0000-4000-8000-000000000001', 42);
  raise notice 'ok：影片列帶正整數 duration_seconds 插入成功';

  -- 正案例：照片、duration_seconds 留 NULL —— 必須成功
  insert into public.media
    (id, family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values
    ('3b000000-0000-4000-8000-0000000000d2', 'fa000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d2.jpg',
     'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001');
  raise notice 'ok：照片列 duration_seconds 留空插入成功';

  -- 正案例（刻意示範，見檔頭）：影片、duration_seconds 也留 NULL —— 必須成功。
  -- DB 不驗 type/duration_seconds 相依關係，這是上傳端契約義務，不是本檔漏測。
  insert into public.media
    (id, family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values
    ('3b000000-0000-4000-8000-0000000000d3', 'fa000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d3.mp4',
     'video', 4096, 1080, 1920, 'a0000000-0000-4000-8000-000000000001');
  raise notice 'ok：影片列 duration_seconds 留空（量測失敗的過渡列）插入成功——DB 不強制 video 必填';

  -- 負案例 A：duration_seconds = 0（media_duration_seconds_positive）
  -- 拿掉這條 CHECK，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       duration_seconds)
    values
      ('3b000000-0000-4000-8000-0000000000d4', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d4.mp4',
       'video', 4096, 1080, 1920, 'a0000000-0000-4000-8000-000000000001', 0);
    raise exception 'FAIL：duration_seconds = 0 的列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：duration_seconds = 0 被 CHECK 擋下 (23514)';
  end;

  -- 負案例 B：duration_seconds < 0（media_duration_seconds_positive）
  -- 拿掉這條 CHECK，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       duration_seconds)
    values
      ('3b000000-0000-4000-8000-0000000000d5', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d5.mp4',
       'video', 4096, 1080, 1920, 'a0000000-0000-4000-8000-000000000001', -1);
    raise exception 'FAIL：duration_seconds = -1 的列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：duration_seconds < 0 被 CHECK 擋下 (23514)';
  end;
end;
$$;

-- ===========================================================================
-- 3. RLS 跨家庭不可讀
--
-- media_select policy（20260822120200_rls_policies.sql）是 row-level
-- （family_id in private.family_ids()），本票新增的欄位不需要、也沒有另外開洞——
-- 這裡直接對「帶時長的列」驗證同一件事，而不是只信任「schema 沒變」的推論。拿掉
-- media_select policy 的 family_id 判準（或改成 using(true)），本段第一個斷言
-- （B 家看到 0 列）會失敗。
-- ===========================================================================
do $$
declare
  v_n bigint;
begin
  -- B 家 owner 查 A 家帶時長的列：必須 0 列
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into v_n from public.media
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and duration_seconds is not null;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：B 家 owner 看到了 A 家 % 列帶時長的 media', v_n;
  end if;

  -- 正向對照：A 家 owner 查自己家帶時長的列：必須看得到剛插入的那一列
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into v_n from public.media
   where id = '3b000000-0000-4000-8000-0000000000d1' and duration_seconds = 42;
  if v_n <> 1 then
    raise exception 'FAIL：A 家 owner 查不到自己剛插入、帶時長的 media 列（影響 % 列）', v_n;
  end if;

  raise notice 'ok 隔離：B 家看不到 A 家帶時長的 media 列（0 列），A 家 owner 查得到自己的（1 列）';
end;
$$;

-- ===========================================================================
-- 4. duration_seconds 一旦 INSERT 即不可 UPDATE
--
-- 比照 storage_path／thumb_path／byte_size／family_id／uploaded_by 的既有慣例
-- （20_role_permissions.sql、98_media_thumbnails.sql 對應段落）：INSERT 時的全欄位
-- 授權不等於之後可以改。若不小心把 duration_seconds 加進 media 的 UPDATE 欄位級
-- grant，本段斷言會從『42501 被擋下』變成『UPDATE 成功、不再進到 exception 分支』
-- 而讓測試變紅。
-- ===========================================================================
do $$
declare
  v_media uuid := '3b000000-0000-4000-8000-0000000000d1';
begin
  begin
    update public.media set duration_seconds = 999 where id = v_media;
    raise exception 'FAIL：上傳者可以改 duration_seconds';
  exception when insufficient_privilege then
    raise notice 'ok：duration_seconds 無 UPDATE 權限 (42501)';
  end;
end;
$$;

reset role;
rollback;
