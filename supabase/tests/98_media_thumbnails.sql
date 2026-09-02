-- LS-128（LS-20 後端）— media 縮圖欄：thumb_path／thumb_width／thumb_height
--
-- 對應 20260902101842_media_thumb_path.sql 的四段自證：
--   1. 欄位存在＋nullable（information_schema）
--   2. CHECK／UNIQUE 正負案例（前綴＝family_id、寬高為正、三欄一致性、路徑唯一）
--   3. RLS 跨家庭不可讀（含 thumb 欄位；既有 media_select policy 是 row-level，
--      新欄位不需要另外開洞）
--   4. thumb_* 三欄一旦 INSERT 即不可 UPDATE（比照 storage_path 的既有慣例）
--
-- 不驗 RPC：get_family_timeline 只回傳 kind/ref_id/occurred_at/child_id 這組最小
-- 指標集合，從未回傳過 media 的任何欄位（見 docs/API.md §4「回傳最小可用的指標
-- 集合」）；縮圖／原圖的實際路徑一律由呼叫端直接查 public.media（RLS 已保護）
-- 取得，不經過這支 RPC。因此本票不改任何 RPC 簽章或回傳型別，這裡也不需要對應
-- 測試——決定記在 migration 檔頭與 PR body。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 欄位存在＋nullable
-- ===========================================================================
do $$
declare
  v_col record;
  v_expected text[] := array['thumb_path', 'thumb_width', 'thumb_height'];
  v_name text;
begin
  foreach v_name in array v_expected loop
    select column_name, is_nullable, data_type into v_col
      from information_schema.columns
     where table_schema = 'public' and table_name = 'media' and column_name = v_name;

    if v_col.column_name is null then
      raise exception 'FAIL：public.media 缺少欄位 %', v_name;
    end if;
    if v_col.is_nullable <> 'YES' then
      raise exception 'FAIL：public.media.% 不是 nullable（is_nullable=%）', v_name, v_col.is_nullable;
    end if;
  end loop;

  raise notice 'ok：thumb_path／thumb_width／thumb_height 三欄存在且皆 nullable';
end;
$$;

-- ===========================================================================
-- 2. CHECK／UNIQUE 正負案例
--
-- 全部以 A 家 owner 身分（有上傳權，INSERT policy 會放行），驗證的是欄位本身的
-- CHECK／UNIQUE，不是 RLS——每個負案例只改一個變數，其餘維持合法值，這樣「拿掉
-- 某條 constraint」時對應的那一個案例會從『擋下』變成『插入成功』而讓測試變紅，
-- 具備鑑別力（PR body 的 mutation 清單逐條對應本段）。
-- ===========================================================================
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  -- 正案例：前綴＝family_id、寬高皆正、三欄同時有值 —— 必須成功
  insert into public.media
    (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
     thumb_path, thumb_width, thumb_height)
  values
    ('3a000000-0000-4000-8000-0000000000f1', 'fa000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f1.jpg',
     'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f1_thumb.jpg',
     200, 150);
  raise notice 'ok：合法縮圖三欄（正確前綴＋正寬高＋三欄同時有值）插入成功';

  -- 正案例：thumb_path／thumb_width／thumb_height 三欄同時留空 —— 必須成功
  -- （過渡期沒有縮圖的列，docs/API.md §4）
  insert into public.media
    (id, family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values
    ('3a000000-0000-4000-8000-0000000000f2', 'fa000000-0000-4000-8000-000000000001',
     'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f2.jpg',
     'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001');
  raise notice 'ok：三欄同時留空（無縮圖的過渡列）插入成功';

  -- 負案例 A：thumb_path 前綴 ≠ family_id（media_thumb_path_family_prefix）
  -- 拿掉這條 CHECK 或改成不比對 family_id，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       thumb_path, thumb_width, thumb_height)
    values
      ('3a000000-0000-4000-8000-0000000000f3', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f3.jpg',
       'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
       -- 前綴故意寫成 B 家
       'fb000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f3_thumb.jpg',
       200, 150);
    raise exception 'FAIL：thumb_path 前綴 ≠ family_id 的列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：thumb_path 前綴 ≠ family_id 被 CHECK 擋下 (23514)';
  end;

  -- 負案例 B：thumb_width <= 0（media_thumb_width_positive）
  -- 拿掉這條 CHECK，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       thumb_path, thumb_width, thumb_height)
    values
      ('3a000000-0000-4000-8000-0000000000f4', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f4.jpg',
       'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f4_thumb.jpg',
       0, 150);
    raise exception 'FAIL：thumb_width = 0 的列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：thumb_width <= 0 被 CHECK 擋下 (23514)';
  end;

  -- 負案例 C：thumb_height <= 0（media_thumb_height_positive）
  -- 拿掉這條 CHECK，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       thumb_path, thumb_width, thumb_height)
    values
      ('3a000000-0000-4000-8000-0000000000f5', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f5.jpg',
       'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f5_thumb.jpg',
       200, -1);
    raise exception 'FAIL：thumb_height = -1 的列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：thumb_height <= 0 被 CHECK 擋下 (23514)';
  end;

  -- 負案例 D：thumb_path 有值但 thumb_width 是 NULL（三欄一致性，
  -- media_thumb_dimensions_consistency）—— 半殘缺狀態：讀取端拿到縮圖路徑卻沒有
  -- 尺寸可以排版。拿掉這條 CHECK，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       thumb_path, thumb_width, thumb_height)
    values
      ('3a000000-0000-4000-8000-0000000000f6', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f6.jpg',
       'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f6_thumb.jpg',
       null, 150);
    raise exception 'FAIL：thumb_path 有值、thumb_width 是 NULL 的半殘缺列竟然插入成功';
  exception when check_violation then
    raise notice 'ok：thumb_path／thumb_width／thumb_height 三欄不一致被 CHECK 擋下 (23514)';
  end;

  -- 負案例 E：thumb_path 撞號（media_thumb_path_key，UNIQUE）
  -- 拿掉這條 UNIQUE，本案例會從『擋下』變成『插入成功』
  begin
    insert into public.media
      (id, family_id, storage_path, type, byte_size, width, height, uploaded_by,
       thumb_path, thumb_width, thumb_height)
    values
      ('3a000000-0000-4000-8000-0000000000f7', 'fa000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f7.jpg',
       'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001',
       -- 跟上面第一個正案例（…f1）撞同一個 thumb_path
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f1_thumb.jpg',
       200, 150);
    raise exception 'FAIL：thumb_path 撞號的列竟然插入成功';
  exception when unique_violation then
    raise notice 'ok：thumb_path 撞號被 UNIQUE 擋下 (23505)';
  end;
end;
$$;

-- ===========================================================================
-- 3. RLS 跨家庭不可讀（含 thumb 欄位）
--
-- media_select policy（20260822120200_rls_policies.sql）是 row-level
-- （family_id in private.family_ids()），本票新增的三個欄位不需要、也沒有另外
-- 開洞——這裡直接對「帶縮圖的列」驗證同一件事，而不是只信任「schema 沒變」的
-- 推論。拿掉 media_select policy 的 family_id 判準（或改成 using(true)），
-- 本段第一個斷言（B 家看到 0 列）會失敗。
-- ===========================================================================
do $$
declare
  v_n bigint;
begin
  -- B 家 owner 查 A 家帶縮圖的列：必須 0 列
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into v_n from public.media
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and thumb_path is not null;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：B 家 owner 看到了 A 家 % 列帶縮圖的 media', v_n;
  end if;

  -- 正向對照：A 家 owner 查自己家帶縮圖的列：必須看得到剛插入的那一列
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into v_n from public.media
   where id = '3a000000-0000-4000-8000-0000000000f1' and thumb_path is not null;
  if v_n <> 1 then
    raise exception 'FAIL：A 家 owner 查不到自己剛插入、帶縮圖的 media 列（影響 % 列）', v_n;
  end if;

  raise notice 'ok 隔離：B 家看不到 A 家帶縮圖的 media 列（0 列），A 家 owner 查得到自己的（1 列）';
end;
$$;

-- ===========================================================================
-- 4. thumb_* 三欄一旦 INSERT 即不可 UPDATE
--
-- 比照 storage_path／byte_size／family_id／uploaded_by 的既有慣例（20_role_
-- permissions.sql 對應段落）：INSERT 時的全欄位授權不等於之後可以改。若不小心
-- 把 thumb_path 等三欄加進 media 的 UPDATE 欄位級 grant，本段三個斷言都會從
-- 『42501 被擋下』變成『UPDATE 成功、不再進到 exception 分支』而讓測試變紅。
-- ===========================================================================
do $$
declare
  v_media uuid := '3a000000-0000-4000-8000-0000000000f1';
begin
  begin
    update public.media set thumb_path =
      'fa000000-0000-4000-8000-000000000001/2026/08/hijack_thumb.jpg'
     where id = v_media;
    raise exception 'FAIL：上傳者可以改 thumb_path（縮圖路徑與實際 Storage 物件會對不上）';
  exception when insufficient_privilege then
    raise notice 'ok：thumb_path 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.media set thumb_width = 999 where id = v_media;
    raise exception 'FAIL：上傳者可以改 thumb_width';
  exception when insufficient_privilege then
    raise notice 'ok：thumb_width 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.media set thumb_height = 999 where id = v_media;
    raise exception 'FAIL：上傳者可以改 thumb_height';
  exception when insufficient_privilege then
    raise notice 'ok：thumb_height 無 UPDATE 權限 (42501)';
  end;
end;
$$;

reset role;
rollback;
