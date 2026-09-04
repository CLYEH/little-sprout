-- LS-40：Storage（media bucket）的 RLS 驗收
--
-- 這個檔案驗的是**檔案本身**的存取邊界，不是 public.media 那張中繼資料表
-- （那由 10_/20_ 驗）。Storage 沒有 family_id 欄位，唯一能表達歸屬的是物件路徑，
-- 所以整組斷言的核心只有一句話：**路徑第一段決定這個檔案屬於誰，而且不能造假**。
--
-- 做法與其他測試檔一致：用 request.jwt.claims 模擬登入者、以 authenticated 角色操作
-- storage.objects，policy 是唯一的閘門（authenticated 對 storage.objects 有完整的
-- table 權限，擋不擋得住完全看 RLS）。每個負向斷言都配一個正向對照——
-- 一條「全部拒絕」的爛 policy 也能讓隔離測試全綠。
--
-- 兩個 storage 平台行為在讀這個檔案之前要先知道：
--   1. storage.objects 上有 statement-level 的 protect_delete trigger，任何 DELETE
--      都會先噴 `42501 Direct deletion from storage tables is not allowed`，
--      除非把 `storage.allow_delete_query` 設成 'true'（storage API 自己就是這樣做的）。
--      不先設它，DELETE 段測到的全是那個 trigger，跟 policy 一點關係也沒有。
--   2. postgres 角色有 BYPASSRLS，所以每一段都必須 `set local role authenticated`
--      才算數；忘了切換的話所有斷言都是假通過。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. 前置檢查：bucket 設定、RLS、四條 policy
--
-- 列舉式而不是「有就好」：bucket 若哪天被人從 dashboard 改成 public，或 policy 被
-- 改成 to public，下面所有隔離斷言仍然會全綠（它們只驗 authenticated 之間的隔離），
-- 但實際上檔案已經全世界可讀。那種漂移只有在這裡列舉才抓得到。
-- ===========================================================================
do $$
declare
  v_public boolean;
  v_limit bigint;
  v_mimes text[];
  v_expected_mimes text[] := array[
    'image/heic', 'image/heif', 'image/jpeg', 'image/png',
    'video/mp4', 'video/quicktime'
  ];
  v_name text;
  v_cmd char;
  v_policies text[] := array[
    'media_bucket_select:r', 'media_bucket_insert:a',
    'media_bucket_update:w', 'media_bucket_delete:d'
  ];
  v_entry text;
  v_unknown text;
begin
  if not exists (
    select 1 from pg_class c where c.oid = 'storage.objects'::regclass and c.relrowsecurity
  ) then
    raise exception 'FAIL：storage.objects 沒有啟用 RLS——四條 policy 全部不會被求值，檔案等於全開';
  end if;

  select b.public, b.file_size_limit, b.allowed_mime_types
    into v_public, v_limit, v_mimes
    from storage.buckets b where b.id = 'media';
  if not found then
    raise exception 'FAIL：找不到 media bucket（20260823030000_storage_policies.sql 沒有套用？）';
  end if;
  if v_public then
    raise exception 'FAIL：media bucket 是 public 的——照片會有公開網址，RLS 形同虛設（PLAN §8）';
  end if;
  if v_limit is distinct from 52428800 then
    raise exception 'FAIL：media bucket 的 file_size_limit 是 %，期望 52428800（50 MiB）', v_limit;
  end if;
  if (select array_agg(m order by m) from unnest(v_mimes) m) is distinct from v_expected_mimes then
    raise exception 'FAIL：media bucket 的 allowed_mime_types 是 %，期望 %', v_mimes, v_expected_mimes;
  end if;

  -- 四條 policy 逐條對名稱、指令別與授予角色
  foreach v_entry in array v_policies loop
    v_name := split_part(v_entry, ':', 1);
    v_cmd  := split_part(v_entry, ':', 2);
    if not exists (
      select 1 from pg_policy p
       where p.polrelid = 'storage.objects'::regclass
         and p.polname = v_name and p.polcmd = v_cmd
         and p.polroles = array['authenticated'::regrole::oid]
    ) then
      raise exception
        'FAIL：storage.objects 上找不到 policy %（指令別 %、且只授予 authenticated）', v_name, v_cmd;
    end if;
  end loop;

  -- 清單外的 policy：fail closed。日後在 storage.objects 上新增 policy（例如第二個
  -- bucket）必須先來這裡登記，否則這道 gate 涵蓋不到它、卻看起來仍然全綠。
  select string_agg(p.polname, '、' order by p.polname) into v_unknown
    from pg_policy p
   where p.polrelid = 'storage.objects'::regclass
     and p.polname <> all (array['media_bucket_select', 'media_bucket_insert',
                                 'media_bucket_update', 'media_bucket_delete']);
  if v_unknown is not null then
    raise exception 'FAIL：storage.objects 出現清單外的 policy —— %（新增 storage policy 必須先到本檔第 1 段登記）', v_unknown;
  end if;

  raise notice 'ok 前置：media bucket 為 private／50 MiB／6 種 MIME，storage.objects RLS 已啟用且只有登記的四條 policy';
end;
$$;

-- ===========================================================================
-- 2. 讀取隔離 + anon + 其他 bucket 不外溢
-- ===========================================================================
begin;

-- 測試用物件（postgres 身分，繞過 RLS）。路徑與 00_fixtures.sql 的 media.storage_path
-- 一模一樣——兩邊本來就該指同一個檔案，用同一組字串才驗得到規約是一致的。
insert into storage.objects (bucket_id, name, owner, owner_id, metadata) values
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', '{"size": 1048576}'),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', '{"size": 2097152}'),
  ('media', 'fb000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-000000000001.jpg',
   'b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', '{"size": 1048576}');

-- 第二個 bucket：policy 的 `bucket_id = 'media'` 若被拿掉，這裡會立刻紅
insert into storage.buckets (id, name, public) values ('ls40-other', 'ls40-other', false);
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('ls40-other', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000b1.jpg',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');

set local role authenticated;

do $$
declare
  v_user text;
  v_n bigint;
begin
  -- A 家三種角色：看得到自家 2 個檔案，看不到 B 家的任何一個，也看不到別的 bucket
  foreach v_user in array array[
    'a0000000-0000-4000-8000-000000000001',  -- owner
    'a0000000-0000-4000-8000-000000000002',  -- member
    'a0000000-0000-4000-8000-000000000003'   -- viewer
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

    if auth.uid() is distinct from v_user::uuid then
      raise exception 'FAIL：auth.uid() = %，claims 沒有生效，本段所有結論無效',
        coalesce(auth.uid()::text, 'NULL');
    end if;

    select count(*) into v_n from storage.objects
     where name like 'fb000000-0000-4000-8000-000000000001/%';
    if v_n <> 0 then
      raise exception 'FAIL 隔離：A 家使用者 % 讀得到 B 家的 % 個檔案', v_user, v_n;
    end if;

    select count(*) into v_n from storage.objects where bucket_id = 'media';
    if v_n <> 2 then
      raise exception 'FAIL：A 家使用者 % 在 media bucket 看到 % 個檔案，期望 2（自家全部、別家 0）',
        v_user, v_n;
    end if;

    select count(*) into v_n from storage.objects where bucket_id = 'ls40-other';
    if v_n <> 0 then
      raise exception 'FAIL：policy 外溢到 ls40-other bucket——A 家使用者 % 讀得到 % 列', v_user, v_n;
    end if;
  end loop;

  -- 反方向
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  select count(*) into v_n from storage.objects
   where name like 'fa000000-0000-4000-8000-000000000001/%';
  if v_n <> 0 then
    raise exception 'FAIL 隔離（反方向）：B 家 owner 讀得到 A 家的 % 個檔案', v_n;
  end if;
  select count(*) into v_n from storage.objects where bucket_id = 'media';
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：B 家 owner 應看到自家 1 個檔案，實際 %', v_n;
  end if;

  raise notice 'ok 隔離：A 家 owner/member/viewer 各看到自家 2 個檔案、B 家 0 個、其他 bucket 0 個；反方向亦然';
end;
$$;

-- 其他 bucket 的寫入也要被擋（policy 只涵蓋 media）
do $$
declare
  v_blocked boolean := false;
  v_state text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  begin
    insert into storage.objects (bucket_id, name, owner, owner_id) values
      ('ls40-other', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000b2.jpg',
       'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：A 家 owner 寫得進 ls40-other bucket——policy 的 bucket_id 限制沒有生效';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：寫入 ls40-other 被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;
  raise notice 'ok：media 以外的 bucket 沒有任何 policy 命中，讀寫皆被拒 (42501)';
end;
$$;

reset role;
set local role anon;

do $$
declare
  v_n bigint;
  v_blocked boolean := false;
  v_state text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  select count(*) into v_n from storage.objects;
  if v_n <> 0 then
    raise exception 'FAIL：未登入者（anon）讀得到 storage.objects 的 % 列', v_n;
  end if;

  begin
    insert into storage.objects (bucket_id, name) values
      ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg');
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：未登入者（anon）寫得進 media bucket';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：anon 寫入被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;

  raise notice 'ok anon：讀到 0 列、寫入被拒 (42501)——四條 policy 都只給 authenticated，anon 沒有任何 policy 命中';
end;
$$;

rollback;

-- ===========================================================================
-- 3. 寫入：正向對照與攻擊探針
-- ===========================================================================
begin;
set local role authenticated;

-- 正向對照先跑：合法路徑必須寫得進去，否則下面「全部被拒」毫無意義
do $$
declare
  v_case record;
begin
  for v_case in
    select * from (values
      ('A 家 owner 上傳原檔（jpg）', 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000a1.jpg'),
      ('A 家 member（can_upload=true）上傳原檔', 'a0000000-0000-4000-8000-000000000002',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000a2.jpg'),
      ('縮圖 _thumb.jpg', 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/12/3a000000-0000-4000-8000-0000000000a3_thumb.jpg'),
      ('影片 .mov', 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2027/01/3a000000-0000-4000-8000-0000000000a4.mov'),
      ('HEIC 原檔', 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000a5.heic'),
      ('B 家 owner 上傳到自己家', 'b0000000-0000-4000-8000-000000000001',
       'fb000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000a1.jpg'),
      -- LS-169：頭像路徑（不寫 media 表，這裡只驗 storage.objects 這一層寫得進去）
      ('A 家 owner 上傳頭像（avatars/{child_id}.jpg）', 'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000a6.jpg'),
      ('A 家 member（can_upload=true）上傳頭像', 'a0000000-0000-4000-8000-000000000002',
       'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000a7.jpg')
    ) as t(label, uid, name)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_case.uid, 'role', 'authenticated')::text, true);
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('media', v_case.name, v_case.uid::uuid, v_case.uid);
    raise notice 'ok 正向：%', v_case.label;
  end loop;
end;
$$;

-- 攻擊探針：每一條都必須以 42501 被拒。
-- 「錯誤碼必須是 42501」不是形式主義：路徑第一段若拿去 cast 成 uuid，格式亂寫的路徑
-- 會噴 22P02（invalid_text_representation）——那是「查詢炸了」不是「權限被拒」，
-- 客戶端拿到的訊息、重試行為、以及日後有人把 policy 包進 exception handler 時的行為
-- 全都不一樣。本 policy 全程不做 cast（比對 uuid::text），所以格式錯只會是一次乾淨的拒絕。
do $$
declare
  v_case record;
  v_blocked boolean;
  v_state text;
  v_msg text;
begin
  for v_case in
    select * from (values
      -- 1) 跨家庭路徑偽造：本票最主要的攻擊面
      ('跨家庭路徑偽造：A 家 owner 把 B 家 family_id 放在第一段',
       'a0000000-0000-4000-8000-000000000001',
       'fb000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000d1.jpg'),
      ('跨家庭路徑偽造：A 家 member 反向偽造',
       'a0000000-0000-4000-8000-000000000002',
       'fb000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000d2.jpg'),
      ('跨家庭路徑偽造：B 家 owner 寫進 A 家',
       'b0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-0000000000d1.jpg'),
      ('不屬於任何相關家庭的第三方帳號寫進 A 家',
       'c0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000d3.jpg'),
      -- 2) 角色：viewer 沒有上傳權（can_upload=false 另有第 4 段的完整演練）
      ('A 家 viewer（can_upload=false）上傳自家路徑',
       'a0000000-0000-4000-8000-000000000003',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000d4.jpg'),
      -- 3) 路徑規約：格式錯必須是拒絕，不是 error
      ('第一段不是 UUID（cast 會噴 22P02 的那種輸入）',
       'a0000000-0000-4000-8000-000000000001',
       'evil/2026/08/3a000000-0000-4000-8000-0000000000d5.jpg'),
      ('第一段是大寫 UUID（Swift 的 UUID.uuidString 預設形態）',
       'a0000000-0000-4000-8000-000000000001',
       'FA000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000d6.jpg'),
      ('沒有第一段：檔案直接放在 bucket 根目錄',
       'a0000000-0000-4000-8000-000000000001',
       '3a000000-0000-4000-8000-0000000000d7.jpg'),
      ('缺 yyyy/mm 兩層',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/3a000000-0000-4000-8000-0000000000d8.jpg'),
      ('月份 13',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/13/3a000000-0000-4000-8000-0000000000d9.jpg'),
      ('檔名不是 UUID',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/family-photo.jpg'),
      ('副檔名不在清單（.exe）',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000da.exe'),
      ('縮圖用了非 .jpg',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000db_thumb.png'),
      ('多墊一層目錄想繞過第一段檢查',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/x/2026/08/3a000000-0000-4000-8000-0000000000dc.jpg'),
      -- LS-169：頭像路徑的同型攻擊面——跨家庭偽造與副檔名偽造
      ('頭像跨家庭路徑偽造：A 家 owner 把 B 家 family_id 放在第一段',
       'a0000000-0000-4000-8000-000000000001',
       'fb000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000dd.jpg'),
      ('頭像副檔名不是 .jpg（.png）',
       'a0000000-0000-4000-8000-000000000001',
       'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000de.png')
    ) as t(label, uid, name)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_case.uid, 'role', 'authenticated')::text, true);

    v_blocked := false;
    begin
      insert into storage.objects (bucket_id, name, owner, owner_id)
      values ('media', v_case.name, v_case.uid::uuid, v_case.uid);
    exception when others then
      v_blocked := true; v_state := sqlstate; v_msg := sqlerrm;
    end;

    if not v_blocked then
      raise exception 'FAIL 攻擊探針未被擋下：%（路徑 %）', v_case.label, v_case.name;
    end if;
    if v_state <> '42501' then
      raise exception
        'FAIL 攻擊探針「%」被拒了，但錯誤碼是 %（%）而不是 42501——這不是一次乾淨的權限拒絕，是別的東西先炸了',
        v_case.label, v_state, v_msg;
    end if;
    raise notice 'ok 攻擊探針被擋下 (42501)：%', v_case.label;
  end loop;
end;
$$;

-- 上傳者欄位只能留空或寫自己（defence in depth）。
-- 沒有這道防線的話，有上傳權的成員可以在自家路徑塞一個 `owner = 別人` 的物件，
-- 而第 6 段那條「上傳者本人」分支認的正是這兩欄——等於把刪除權硬塞給沒上傳過的人。
-- 「留空要放行」也要驗：storage-api 依版本可能只寫其中一欄，兩欄都強制非空會讓
-- 上傳在某些版本直接失敗（那種失敗只會在雲端出現，本機測不到，所以這裡先釘住）。
do $$
declare
  v_case record;
  v_blocked boolean;
  v_state text;
begin
  -- 全程以 A 家 owner（a0…0001）身分寫入；「他人」指 A 家 member（a0…0002）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

  for v_case in
    select * from (values
      ('owner=本人, owner_id=他人',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f1.jpg',
       'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', false),
      ('owner=他人, owner_id=本人',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f2.jpg',
       'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', false),
      ('owner=他人, owner_id=他人',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f3.jpg',
       'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', false),
      ('owner=NULL, owner_id=NULL',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f4.jpg',
       null, null, true),
      ('owner=NULL, owner_id=本人',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f5.jpg',
       null, 'a0000000-0000-4000-8000-000000000001', true),
      ('owner=本人, owner_id=NULL',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000f6.jpg',
       'a0000000-0000-4000-8000-000000000001', null, true)
    ) as t(label, name, o_owner, o_owner_id, expect_ok)
  loop
    v_blocked := false;
    begin
      insert into storage.objects (bucket_id, name, owner, owner_id)
      values ('media', v_case.name, v_case.o_owner::uuid, v_case.o_owner_id);
    exception when others then
      v_blocked := true; v_state := sqlstate;
    end;

    if v_case.expect_ok and v_blocked then
      raise exception 'FAIL：合法的上傳者欄位組合「%」被擋下了（%）——storage-api 只寫一欄的版本會上傳不了',
        v_case.label, v_state;
    end if;
    if not v_case.expect_ok then
      if not v_blocked then
        raise exception 'FAIL：上傳者欄位組合「%」沒有被擋下——可以把刪除權塞給沒上傳過那個檔案的人', v_case.label;
      end if;
      if v_state <> '42501' then
        raise exception 'FAIL：上傳者欄位組合「%」被拒，但錯誤碼是 % 而不是 42501', v_case.label, v_state;
      end if;
    end if;
    raise notice 'ok 上傳者欄位：% → %', v_case.label,
      case when v_case.expect_ok then '放行' else '擋下 (42501)' end;
  end loop;
end;
$$;

rollback;

-- ===========================================================================
-- 4. can_upload 負向演練：正向 → 關掉 can_upload → 被拒 → 還原 → 再正向
--
-- 三段一起做才證明得了「拒絕是 can_upload 造成的」：只驗中間那段被拒，
-- 一個把 member 整個擋掉的爛 policy 也會通過。
-- （整段在交易裡，rollback 之後 can_upload 回到 fixtures 的原值；
--   但還原那一步照樣明寫，不倚賴 rollback——後面還有正向對照要跑。）
-- ===========================================================================
begin;

set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  insert into storage.objects (bucket_id, name, owner, owner_id) values
    ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000e1.jpg',
     'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');
  raise notice 'ok can_upload 演練（前）：can_upload=true 的 member 上傳成功';
end;
$$;

reset role;
update public.family_members set can_upload = false
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

set local role authenticated;
do $$
declare
  v_blocked boolean := false;
  v_state text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  begin
    insert into storage.objects (bucket_id, name, owner, owner_id) values
      ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000e2.jpg',
       'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：can_upload 被關掉之後，member 仍然上傳得了檔案';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：can_upload=false 的上傳被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;

  -- 同一個人此時仍應「讀得到」自家檔案：can_upload 管的是寫，不是讀
  if (select count(*) from storage.objects where bucket_id = 'media') = 0 then
    raise exception 'FAIL：can_upload=false 連帶讓成員讀不到自家檔案——關錯了東西';
  end if;
  raise notice 'ok can_upload 演練（中）：can_upload=false 的 member 上傳被拒 (42501)，讀取不受影響';
end;
$$;

reset role;
update public.family_members set can_upload = true
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  insert into storage.objects (bucket_id, name, owner, owner_id) values
    ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000e3.jpg',
     'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');
  raise notice 'ok can_upload 演練（後）：還原 can_upload=true 後上傳恢復——中段的拒絕確實來自 can_upload';
end;
$$;

rollback;

-- ===========================================================================
-- 5. 改名／搬移（UPDATE）與刪除（DELETE）
-- ===========================================================================
begin;

-- protect_delete 是 statement-level trigger，會先於 policy 把所有 DELETE 擋掉，
-- 不解開它的話第 5-2 段測到的全是那個 trigger（storage API 自己也是這樣設）。
set local storage.allow_delete_query = 'true';

insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001'),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002'),
  ('media', 'fb000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-000000000001.jpg',
   'b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001');

set local role authenticated;

-- 5-1 UPDATE
do $$
declare
  v_n int;
  v_blocked boolean;
  v_state text;
begin
  -- 上傳者本人改自己的檔案（storage API 覆寫同名檔就是走 UPDATE）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 4194304}'
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：上傳者改不動自己的檔案（影響 % 列）', v_n;
  end if;

  -- 別人上傳的檔案：member 改不動（他不是上傳者也不是 owner）
  update storage.objects set metadata = '{"size": 1}'
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：A 家 member 改得動 owner 上傳的檔案（影響 % 列）', v_n;
  end if;

  -- 家庭 owner 可以改任何一個自家檔案（§9-A1 移除內容）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 8388608}'
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：家庭 owner 改不動成員上傳的檔案（影響 % 列）', v_n;
  end if;

  -- 跨家庭 UPDATE：影響 0 列（USING 濾掉，不會噴錯）
  update storage.objects set metadata = '{"size": 1}'
   where name like 'fb000000-0000-4000-8000-000000000001/%';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：A 家 owner 的 UPDATE 影響了 B 家 % 列', v_n;
  end if;

  -- 改名搬家：把自家檔案改成 B 家的路徑前綴——WITH CHECK 必須擋（這是 INSERT 防線的側門）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  v_blocked := false;
  begin
    update storage.objects
       set name = 'fb000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg'
     where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：成員把自家檔案改名搬進 B 家路徑成功了——UPDATE 的 WITH CHECK 沒有擋住';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：改名搬家被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;

  -- 改成不合規約的路徑也要擋
  v_blocked := false;
  begin
    update storage.objects
       set name = 'fa000000-0000-4000-8000-000000000001/whatever.jpg'
     where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：檔案被改成不合路徑規約的名字';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：改成不合規約的路徑被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;

  -- 釘樁探針（LS-40 review F10）：member 把自己上傳檔案的 owner 改成同家庭別人，
  -- 想藉此把「上傳者本人」分支認的身分轉送給沒上傳過這個檔案的人——UPDATE 的
  -- WITH CHECK 補了與 INSERT 相同的兩行釘樁之後，這條側門必須被擋下。
  -- 「42501 或 0 列」都算擋下：擋下的形式取決於 policy 求值細節，這裡不押注是哪一種，
  -- 只要求兩者之一，且擋下之後不能有第二筆物件被塞進 owner=別人的狀態。
  v_blocked := false;
  begin
    update storage.objects
       set owner = 'a0000000-0000-4000-8000-000000000001'::uuid
     where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if v_blocked then
    if v_state <> '42501' then
      raise exception 'FAIL：member 把 owner 改成同家庭他人被拒，但錯誤碼是 % 而不是 42501', v_state;
    end if;
  else
    get diagnostics v_n = row_count;
    if v_n <> 0 then
      raise exception 'FAIL：member 把自己上傳檔案的 owner 改成同家庭他人成功了（影響 % 列）——把改／刪權轉送給了沒上傳過這個檔案的人', v_n;
    end if;
  end if;
  raise notice 'ok 釘樁：member 無法把自己檔案的 owner 改成同家庭他人（% 擋下）',
    case when v_blocked then '42501' else '0 列' end;

  raise notice 'ok UPDATE：上傳者與家庭 owner 改得動、他人改不動、跨家庭 0 列、改名搬家與違規路徑皆被 WITH CHECK 擋下 (42501)';
end;
$$;

-- 5-2 DELETE
do $$
declare
  v_n int;
begin
  -- viewer 刪不掉任何東西
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  delete from storage.objects where bucket_id = 'media';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：A 家 viewer 刪掉了 % 個檔案', v_n;
  end if;

  -- B 家 owner 刪不掉 A 家的檔案
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  delete from storage.objects where name like 'fa000000-0000-4000-8000-000000000001/%';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：B 家 owner 刪掉了 A 家的 % 個檔案', v_n;
  end if;

  -- member 刪不掉別人上傳的
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：A 家 member 刪掉了 owner 上傳的檔案';
  end if;

  -- 但刪得掉自己上傳的（失敗上傳留下的孤兒物件只有上傳者知道它存在）
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：上傳者刪不掉自己上傳的檔案（影響 % 列）', v_n;
  end if;

  -- 家庭 owner 刪得掉自家任何一個
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照：家庭 owner 刪不掉自家檔案（影響 % 列）', v_n;
  end if;

  raise notice 'ok DELETE：viewer／跨家庭／他人檔案皆 0 列；上傳者刪自己的、家庭 owner 刪自家的各 1 列';
end;
$$;

rollback;

-- ===========================================================================
-- 5b. 頭像路徑的 UPDATE／DELETE：與 update_child 同一角色判準（LS-169 R2 M1）
--
-- 承上一段：`{yyyy}/{mm}` media 物件的「上傳者本人」判準對頭像固定路徑不適用——
-- 孩子頭像是家庭共有物，orchestrator 裁定改用 `private.contributor_family_ids()`
-- （owner／member，不看 can_upload，逐字比照 `update_child` 本身的授權判準）。
-- 這裡直接以超級使用者身分種一筆「owner 上傳的頭像物件」（owner 欄位＝A 家 owner），
-- 驗證 member／viewer／跨家庭三種角色對它的 UPDATE／DELETE 行為，以及既有
-- `{yyyy}/{mm}` 分支（上一段已驗）完全不受影響。**注意**：以下探針直接對已存在
-- 物件下 SQL UPDATE／DELETE，驗證的是這兩條 policy 本身的角色判準；app 實際換頭像
-- 走 Storage API 的 upsert，另受 INSERT policy 的 can_upload 節制——兩者的差異見
-- can_upload=false 那個區塊前的完整說明（LS-169 R3 n1）。
-- ===========================================================================
begin;
set local storage.allow_delete_query = 'true';

insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');

set local role authenticated;

do $$
declare
  v_n int;
begin
  -- member（can_upload=true，既有 fixture）覆蓋 owner 上傳的頭像——這是 merge-review R1
  -- M1 實測會被拒的情境，也是 i4 點名要補的探針：owner 上傳→member 覆蓋同一路徑。
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 999}'
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL M1：可編輯孩子資料的 member 覆蓋不了 owner 上傳的頭像（影響 % 列）——family 角色判準沒生效', v_n;
  end if;
  raise notice 'ok M1：member（owner／member 皆可編輯孩子資料）覆蓋 owner 上傳的頭像成功';
end;
$$;

-- 關掉這個 member 的 can_upload，驗證「頭像的 UPDATE policy 角色判準」真的不看
-- can_upload——跟 update_child 的授權判準逐字一致（role in ('owner','member')，沒有
-- can_upload 這個條件）。若這裡意外要求 can_upload，這一段會紅（跟第 4 段驗證既有
-- media 路徑「看 can_upload」剛好是對照組，兩段合起來把「頭像分支跟既有分支判準
-- 不同」這件事釘住）。
--
-- 重要（LS-169 R3 n1）：下面這條探針直接對已存在的 row 下 SQL UPDATE，只驗證
-- `media_bucket_update` 這條 policy 本身的角色判準——不代表 app 真實換頭像的行為。
-- client 唯一會走的路徑是 Storage API 的 `upsert: true`（storage-api 內部走
-- INSERT ... ON CONFLICT DO UPDATE），這條路徑同時要過 INSERT policy 的 WITH CHECK
-- （`uploadable_family_ids()`，member 仍看 can_upload——本輪刻意沒有放寬，見
-- docs/API.md §6「寶貝大頭照」小節）。也就是說：can_upload=false 的 member 在這條
-- 探針測到「SQL UPDATE 成功」，但同一個人在真實 app 裡換頭像會在 INSERT policy 那關
-- 被擋（400 `new row violates row-level security policy`）——這條探針只釘住 UPDATE
-- policy 這一層的角色判準沒有意外收緊，不是在斷言「can_upload=false 的 member 換得
-- 了頭像」。
update public.family_members set can_upload = false
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 1000}'
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：media_bucket_update 的角色判準意外收緊了——can_upload=false 的 member 對已存在頭像物件的 SQL UPDATE 應該仍通過這條 policy（判準只看 role in owner/member，不看 can_upload），實際影響 % 列', v_n;
  end if;
  raise notice 'ok：media_bucket_update policy 角色判準不看 can_upload（can_upload=false 的 member 對 SQL UPDATE 仍通過這條 policy）——但這不代表這個角色能透過 app 換頭像：app 的 upsert 路徑另受 INSERT policy 的 can_upload 節制，見上方註解（LS-169 R3 n1）';
end;
$$;

update public.family_members set can_upload = true
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  v_n int;
begin
  -- viewer 不是 contributor，覆蓋不了頭像
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 1}'
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：A 家 viewer 覆蓋了頭像（影響 % 列）——viewer 不該是 contributor', v_n;
  end if;

  -- 跨家庭：B 家 owner 動不了 A 家的頭像
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  update storage.objects set metadata = '{"size": 1}'
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 隔離：B 家 owner 覆蓋了 A 家的頭像（影響 % 列）', v_n;
  end if;

  -- DELETE 同一組判準：member 刪得掉，viewer／跨家庭刪不掉
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：A 家 viewer 刪掉了頭像（影響 % 列）', v_n;
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL M1：member 刪不掉頭像（影響 % 列）', v_n;
  end if;

  raise notice 'ok M1：頭像 UPDATE／DELETE 與 update_child 同一角色判準——member 可覆蓋／可刪、viewer 與跨家庭皆擋下';
end;
$$;

-- 改名搬家側門對頭像分支同樣要擋：member 把自家頭像路徑改名搬進 B 家——WITH CHECK
-- 的 family 分支只看「新路徑」的第一段，這裡驗證新路徑跨家庭時仍被擋。
-- reset role：這一段前面幾個 do 區塊切過 JWT claims／authenticated 角色，種 fixture
-- 前先切回 postgres（繞過 RLS）才能自由指定 owner 欄位，同本檔案其餘 fixture 種法一致。
reset role;
insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000f1.jpg',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');
set local role authenticated;

do $$
declare
  v_blocked boolean := false;
  v_state text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  begin
    update storage.objects
       set name = 'fb000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000f1.jpg'
     where name = 'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-0000000000f1.jpg';
  exception when others then
    v_blocked := true; v_state := sqlstate;
  end;
  if not v_blocked then
    raise exception 'FAIL：member 把自家頭像改名搬進 B 家路徑成功了——頭像分支的 WITH CHECK 沒有擋住跨家庭搬移';
  end if;
  if v_state <> '42501' then
    raise exception 'FAIL：頭像改名搬家被拒，但錯誤碼是 % 而不是 42501', v_state;
  end if;
  raise notice 'ok M1：頭像路徑改名搬進別家一樣被 WITH CHECK 擋下 (42501)';
end;
$$;

rollback;

-- ===========================================================================
-- 6. 「上傳者本人」的 (owner, owner_id) 五種組合
--
-- policy 用的是 `owner = me OR owner_id = me`——兩欄都認，因為 storage-api 依版本
-- 可能只寫其中一欄。問題是：第 5 段（以及其他所有段落）每一筆 insert 都同時塞了
-- 兩欄且同值，所以把那個 OR 改成 AND，全套測試仍然會綠——那條 OR 等於零覆蓋，
-- 「不押在 storage 版本行為上」這個保證根本沒有被釘住（LS-40 review F1）。
--
-- 這一段逐一列舉五種組合，對 member 驗 UPDATE 與 DELETE 的 row_count：
--   (本人, 本人) (NULL, 本人) (本人, NULL) → 動得了（1 列）
--   (他人, NULL) (NULL, NULL)             → 動不了（0 列）
-- 最後一組正向對照最重要：兩欄皆空時**退化成「只有家庭 owner 能動」，不是「沒人能動」**。
-- 少了那條對照，一個把所有人都擋掉的爛 policy 也會讓這一段全綠。
-- ===========================================================================
begin;
set local storage.allow_delete_query = 'true';

insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000091.jpg',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002'),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000092.jpg',
   null, 'a0000000-0000-4000-8000-000000000002'),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000093.jpg',
   'a0000000-0000-4000-8000-000000000002', null),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000094.jpg',
   'a0000000-0000-4000-8000-000000000001', null),
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000095.jpg',
   null, null);

set local role authenticated;

do $$
declare
  v_case record;
  v_n int;
  v_want int;
begin
  -- 以 A 家 member 身分（他不是家庭 owner，所以只有「上傳者本人」那條分支能救他）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

  for v_case in
    select * from (values
      ('(owner=本人, owner_id=本人)',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000091.jpg', true),
      ('(owner=NULL, owner_id=本人)',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000092.jpg', true),
      ('(owner=本人, owner_id=NULL)',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000093.jpg', true),
      ('(owner=他人, owner_id=NULL)',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000094.jpg', false),
      ('(owner=NULL, owner_id=NULL)',
       'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000095.jpg', false)
    ) as t(label, name, allowed)
  loop
    v_want := case when v_case.allowed then 1 else 0 end;

    update storage.objects set metadata = '{"ls40_probe": true}' where name = v_case.name;
    get diagnostics v_n = row_count;
    if v_n <> v_want then
      raise exception 'FAIL 上傳者欄位組合 %：member 的 UPDATE 影響 % 列，期望 % 列', v_case.label, v_n, v_want;
    end if;

    delete from storage.objects where name = v_case.name;
    get diagnostics v_n = row_count;
    if v_n <> v_want then
      raise exception 'FAIL 上傳者欄位組合 %：member 的 DELETE 影響 % 列，期望 % 列', v_case.label, v_n, v_want;
    end if;

    raise notice 'ok 上傳者欄位組合 %：member 的 UPDATE／DELETE 各影響 % 列', v_case.label, v_want;
  end loop;

  -- 正向對照：member 動不了的那兩筆，家庭 owner 動得了（＝退化方向是「歸 owner」而非「沒人能動」）
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  delete from storage.objects where name in (
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000094.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000095.jpg');
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'FAIL 正向對照：家庭 owner 應刪得掉那 2 筆 member 動不了的物件，實際 % 列（兩欄皆空時退化成「沒人能動」，孤兒檔案永遠清不掉）', v_n;
  end if;

  raise notice 'ok 上傳者欄位：五種 (owner, owner_id) 組合行為皆符合設計，且兩欄皆空時由家庭 owner 接手';
end;
$$;

rollback;

-- ===========================================================================
-- 7. can_upload 被收回之後，成員連自己上傳的檔案也動不了（刻意選較嚴的一邊）
--
-- policy 的上傳者分支要求「**當下仍**在 uploadable_family_ids() 裡」，不是
-- 「上傳當時有權」。這是設計選擇不是疏漏：can_upload 的語義是「這個人現在不該再寫
-- 這個 bucket」，留一條「但他還能刪」的縫等於權限只撤了一半。
-- 代價是被撤權成員留下的孤兒物件要由家庭 owner 清——那條契約寫在 docs/PLAN.md §5，
-- 這裡把它釘成斷言：日後若有人改成寬鬆版（看上傳當時的權限），這一段會先紅。
-- ===========================================================================
begin;
set local storage.allow_delete_query = 'true';

insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');

set local role authenticated;
do $$
declare
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  update storage.objects set metadata = '{"ls40_probe": true}'
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 前置：can_upload=true 的成員應動得了自己上傳的檔案，實際 % 列', v_n;
  end if;
  raise notice 'ok 撤權演練（前）：can_upload=true 時，上傳者動得了自己的檔案';
end;
$$;

reset role;
update public.family_members set can_upload = false
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

set local role authenticated;
do $$
declare
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

  update storage.objects set metadata = '{"ls40_probe2": true}'
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：can_upload 被收回後，成員仍改得動自己以前上傳的檔案（影響 % 列）——權限只撤了一半', v_n;
  end if;

  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL：can_upload 被收回後，成員仍刪得掉自己以前上傳的檔案（影響 % 列）', v_n;
  end if;

  -- 讀取不受影響：撤的是寫入權，不是家庭成員身分
  if (select count(*) from storage.objects where bucket_id = 'media') <> 1 then
    raise exception 'FAIL：撤權連帶讓成員看不到自家檔案——關錯了東西';
  end if;

  -- 契約的另一半：孤兒物件由家庭 owner 清得掉
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  delete from storage.objects
   where name = 'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-0000000000c1.jpg';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL 契約：被撤權成員留下的孤兒物件，家庭 owner 也清不掉（影響 % 列）——那個檔案就永遠留在那裡了', v_n;
  end if;

  raise notice 'ok 撤權演練（中）：被撤權成員改不動也刪不掉自己以前的檔案（讀取不受影響），孤兒物件由家庭 owner 清理';
end;
$$;

reset role;
update public.family_members set can_upload = true
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

rollback;

-- ===========================================================================
-- 8. 路徑規約判斷式本身的列舉驗證
--
-- 第 3 段是「經由 policy」驗規約，這一段直接驗 private.is_media_object_path()。
-- （承上：第 6、7 段驗的是「誰動得了既有物件」，與規約本身無關。）
-- 兩段都要：policy 那段證明規約真的接在寫入路徑上，這段證明規約本身的邊界正確
-- （policy 那段若哪天把規約條件拿掉，這段仍會綠——所以它不能取代第 3 段，反之亦然）。
-- ===========================================================================
do $$
declare
  v_name text;
  v_good text[] := array[
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/01/3a000000-0000-4000-8000-000000000001.jpeg',
    'fa000000-0000-4000-8000-000000000001/2026/12/3a000000-0000-4000-8000-000000000001.png',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.heic',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.heif',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.mp4',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.mov',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001_thumb.jpg',
    -- LS-169：頭像路徑新形狀 {family_id}/avatars/{child_id}.jpg
    'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.jpg'
  ];
  v_bad text[] := array[
    'fa000000-0000-4000-8000-000000000001/2026/00/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/13/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/8/3a000000-0000-4000-8000-000000000001.jpg',
    'FA000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/08/3A000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.JPG',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001_thumb.png',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg.exe',
    'fa000000-0000-4000-8000-000000000001/2026/08/photo.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/08/x/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/3a000000-0000-4000-8000-000000000001.jpg',
    '3a000000-0000-4000-8000-000000000001.jpg',
    -- 前後多餘的東西：^ 與 $ 沒鎖好的話這兩條會漏
    'x/fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg/x',
    -- LS-169：頭像路徑新形狀的邊界——大寫、非 .jpg、檔名不是 UUID、多墊一層都要擋
    'fa000000-0000-4000-8000-000000000001/avatars/3a000000-0000-4000-8000-000000000001.png',
    'fa000000-0000-4000-8000-000000000001/avatars/3A000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/avatars/child.jpg',
    'fa000000-0000-4000-8000-000000000001/avatars/x/3a000000-0000-4000-8000-000000000001.jpg',
    'fa000000-0000-4000-8000-000000000001/Avatars/3a000000-0000-4000-8000-000000000001.jpg'
  ];
begin
  foreach v_name in array v_good loop
    if not private.is_media_object_path(v_name) then
      raise exception 'FAIL 路徑規約：合法路徑被判為不合規 —— %', v_name;
    end if;
  end loop;

  foreach v_name in array v_bad loop
    if private.is_media_object_path(v_name) then
      raise exception 'FAIL 路徑規約：不合規的路徑被判為合法 —— %', v_name;
    end if;
  end loop;

  if private.is_media_object_path(null) is not false
     and private.is_media_object_path(null) is not null then
    raise exception 'FAIL 路徑規約：NULL 路徑的判斷結果既不是 false 也不是 NULL';
  end if;

  raise notice 'ok 路徑規約：% 條合法全過、% 條不合規全擋、NULL 不會被判為合法',
    array_length(v_good, 1), array_length(v_bad, 1);
end;
$$;
