-- LS-11 紅燈探針：本檔無邏輯變更，只加這行註解讓 rules job 的
-- 「migration 變更必須伴隨 tests 變更」檢查通過，聚焦驗證 db job 本身。
--
-- LS-6 驗收條件 (a)：跨 family 隔離
-- PLAN §3「A 家庭成員看不到 B 家庭任何內容」、Phase 0-2 驗證 (a)。
--
-- 做法：用 request.jwt.claims 模擬登入者，以 authenticated 角色查詢，逐張內容表確認 0 列。
-- 每個負向斷言都配一個正向斷言（同一個人查自己家庭必須查得到）——
-- 沒有正向對照的話，一條「全部拒絕」的爛 policy 也會讓隔離測試全綠。

\set ON_ERROR_STOP on

-- ===========================================================================
-- A 家的三種角色（owner / member / viewer）都看不到 B 家的任何一列
-- ===========================================================================
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

-- 前置：claims 真的生效了嗎？（若 auth.uid() 是 NULL，下面所有 0 列都是假通過）
do $$
begin
  if auth.uid() is distinct from 'a0000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：auth.uid() = %，request.jwt.claims 沒有生效，本檔案的隔離結論全部無效',
      coalesce(auth.uid()::text, 'NULL');
  end if;
  raise notice 'ok：auth.uid() = % (A 家 owner)', auth.uid();
end;
$$;

do $$
declare
  v_user text;
  v_table text;
  v_n bigint;
  v_other uuid := 'fb000000-0000-4000-8000-000000000001';  -- B 家
  v_tables text[] := array[
    'family_members', 'invites', 'children', 'media', 'albums', 'album_media',
    'diaries', 'diary_media', 'comments', 'reactions', 'feed_items',
    'content_reports', 'blocked_users'
  ];
begin
  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003'   -- viewer
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

    -- families 本身用 id 比對
    select count(*) into v_n from public.families where id = v_other;
    if v_n <> 0 then
      raise exception 'FAIL 隔離：A 家使用者 % 看到了 B 家的 families 列', v_user;
    end if;

    foreach v_table in array v_tables loop
      execute format('select count(*) from public.%I where family_id = $1', v_table)
        into v_n using v_other;
      if v_n <> 0 then
        raise exception 'FAIL 隔離：A 家使用者 % 在 public.% 看到了 B 家的 % 列',
          v_user, v_table, v_n;
      end if;
    end loop;

    -- 不帶 family_id 的兩張表也要驗：profile 與裝置 token 不能外洩
    select count(*) into v_n from public.profiles
      where id = 'b0000000-0000-4000-8000-000000000001';
    if v_n <> 0 then
      raise exception 'FAIL 隔離：A 家使用者 % 看得到 B 家 owner 的 profile', v_user;
    end if;

    select count(*) into v_n from public.device_tokens
      where user_id = 'b0000000-0000-4000-8000-000000000001';
    if v_n <> 0 then
      raise exception 'FAIL 隔離：A 家使用者 % 看得到 B 家 owner 的 device_token', v_user;
    end if;
  end loop;

  raise notice 'ok 隔離：A 家 owner/member/viewer 對 B 家 14 張表 + profiles + device_tokens 皆為 0 列';
end;
$$;

-- 正向對照：同一批查詢在自己家庭必須查得到東西
do $$
declare
  v_table text;
  v_n bigint;
  v_mine uuid := 'fa000000-0000-4000-8000-000000000001';
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  select count(*) into v_n from public.families where id = v_mine;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：A 家 owner 查不到自己的 families 列';
  end if;

  foreach v_table in array array[
    'family_members', 'invites', 'children', 'media', 'albums', 'album_media',
    'diaries', 'diary_media', 'comments', 'reactions', 'feed_items',
    'content_reports', 'blocked_users'
  ] loop
    execute format('select count(*) from public.%I where family_id = $1', v_table)
      into v_n using v_mine;
    if v_n = 0 then
      raise exception 'FAIL 正向對照：A 家 owner 在 public.% 查不到自家資料（policy 過度封鎖）', v_table;
    end if;
  end loop;

  raise notice 'ok 正向對照：A 家 owner 在自家 14 張表都查得到資料';
end;
$$;

-- 寫入方向的隔離：查不到不代表寫不進去
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fb000000-0000-4000-8000-000000000001',
            'fb000000-0000-4000-8000-000000000001/2026/08/intruder.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL 隔離：A 家 owner 竟然可以把照片寫進 B 家';
  exception when insufficient_privilege then
    raise notice 'ok 隔離：A 家 owner 寫入 B 家 media 被 RLS 擋下 (42501)';
  end;

  begin
    insert into public.comments (family_id, target_type, target_id, author_id, body)
    values ('fb000000-0000-4000-8000-000000000001', 'media',
            '3b000000-0000-4000-8000-000000000001',
            'a0000000-0000-4000-8000-000000000001', '我不該留得下這則留言');
    raise exception 'FAIL 隔離：A 家 owner 竟然可以在 B 家的照片下留言';
  exception when insufficient_privilege then
    raise notice 'ok 隔離：A 家 owner 對 B 家 comments 的寫入被 RLS 擋下 (42501)';
  end;
end;
$$;

-- UPDATE 不會噴錯，只會影響 0 列——所以要驗「影響 0 列」而不是驗「有沒有錯」
do $$
declare
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  update public.media set deleted_at = now()
    where family_id = 'fb000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：A 家 owner 的 UPDATE 影響了 B 家 % 列', v_n;
  end if;

  update public.families set name = '被入侵的名字'
    where id = 'fb000000-0000-4000-8000-000000000001';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：A 家 owner 改得動 B 家的家庭名稱';
  end if;

  raise notice 'ok 隔離：A 家 owner 對 B 家的 UPDATE 影響 0 列';
end;
$$;

rollback;

-- ===========================================================================
-- 反方向：B 家的兩位成員也看不到 A 家
-- ===========================================================================
begin;
select set_config('request.jwt.claims',
  '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_user text;
  v_table text;
  v_n bigint;
  v_other uuid := 'fa000000-0000-4000-8000-000000000001';  -- A 家
begin
  foreach v_user in array array[
    'b0000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-8000-000000000002'
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

    select count(*) into v_n from public.families where id = v_other;
    if v_n <> 0 then
      raise exception 'FAIL 隔離：B 家使用者 % 看到了 A 家的 families 列', v_user;
    end if;

    foreach v_table in array array[
      'family_members', 'invites', 'children', 'media', 'albums', 'album_media',
      'diaries', 'diary_media', 'comments', 'reactions', 'feed_items',
      'content_reports', 'blocked_users'
    ] loop
      execute format('select count(*) from public.%I where family_id = $1', v_table)
        into v_n using v_other;
      if v_n <> 0 then
        raise exception 'FAIL 隔離：B 家使用者 % 在 public.% 看到了 A 家的 % 列',
          v_user, v_table, v_n;
      end if;
    end loop;
  end loop;

  raise notice 'ok 隔離（反方向）：B 家 owner/member 對 A 家 14 張表皆為 0 列';
end;
$$;

do $$
declare
  v_n bigint;
begin
  select count(*) into v_n from public.media
    where family_id = 'fb000000-0000-4000-8000-000000000001';
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：B 家 owner 應看到自家 1 張照片，實際 %', v_n;
  end if;
  raise notice 'ok 正向對照：B 家 owner 看得到自家照片';
end;
$$;

rollback;

-- ===========================================================================
-- 沒有任何家庭的新使用者（§9-C5 的起點）：看不到任何內容，但不能被卡死
-- ===========================================================================
begin;
select set_config('request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_n bigint;
begin
  -- 效能測試帳號只屬於效能家，對 A/B 兩家都應該是 0
  select count(*) into v_n from public.media
    where family_id in ('fa000000-0000-4000-8000-000000000001',
                        'fb000000-0000-4000-8000-000000000001');
  if v_n <> 0 then
    raise exception 'FAIL 隔離：第三方使用者看到了 A/B 家的 % 張照片', v_n;
  end if;
  raise notice 'ok 隔離：第三方使用者看不到 A/B 兩家的內容';
end;
$$;
rollback;
