-- LS-6 測試資料（以 postgres 身分執行，繞過 RLS）
--
-- 兩個對稱的家庭，讓「A 看不到 B」與「B 看不到 A」兩個方向都能驗。
-- 固定 UUID，讓測試可重複執行：每次先把這些家庭與使用者刪掉再建。
--
-- UUID 命名規約（第一段的頭兩碼即實體種類與所屬家庭，只用合法的 16 進位字元）：
--   fa/fb/fc……family A / family B / 效能測試家庭
--   a0/b0/c0 …… 家庭 A / B / 效能家 的使用者（末碼 1,2,3 = owner, member, viewer）
--   1x invites   2x children   3x media   4x albums   5x diaries
--   6x comments  7x reactions  8x content_reports        （x = a 屬 A 家、b 屬 B 家）
--
-- 注意：家庭的 owner 列不在這裡手動插入——families 的 AFTER INSERT trigger
-- 會把 created_by 寫成 owner（private.add_creator_as_owner）。這裡只補其他成員。

\set ON_ERROR_STOP on

-- 先刪家庭再刪使用者：刪家庭會 cascade 掉成員（此時家庭已不存在，owner 不變量 trigger 不會誤擋）；
-- 反過來先刪使用者會讓家庭剩下 0 個 owner 而被 trigger 擋下。
delete from public.families where id in (
  'fa000000-0000-4000-8000-000000000001',
  'fb000000-0000-4000-8000-000000000001',
  'fc000000-0000-4000-8000-000000000001'
);
delete from auth.users where id in (
  'a0000000-0000-4000-8000-000000000001',
  'a0000000-0000-4000-8000-000000000002',
  'a0000000-0000-4000-8000-000000000003',
  'b0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'c0000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('a0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a-owner@ls6.test',  now(), now(), '{}', '{}'),
  ('a0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a-member@ls6.test', now(), now(), '{}', '{}'),
  ('a0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a-viewer@ls6.test', now(), now(), '{}', '{}'),
  ('b0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'b-owner@ls6.test',  now(), now(), '{}', '{}'),
  ('b0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'b-member@ls6.test', now(), now(), '{}', '{}'),
  ('c0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'perf@ls6.test',     now(), now(), '{}', '{}');

-- LS-110：上面的 auth.users insert 已經觸發 trigger 自動建立 profiles 列（display_name
-- 推導自 email 帳號部分），這裡用 on conflict do update 覆寫成 fixture 要的固定名稱
-- ——後面測試（例如 87_comments_reactions_notifications.sql 驗 author_display_name）
-- 依賴的是這裡的名字，不是 trigger 推導出來的。
insert into public.profiles (id, display_name) values
  ('a0000000-0000-4000-8000-000000000001', 'A 家爸爸'),
  ('a0000000-0000-4000-8000-000000000002', 'A 家媽媽'),
  ('a0000000-0000-4000-8000-000000000003', 'A 家阿嬤'),
  ('b0000000-0000-4000-8000-000000000001', 'B 家爸爸'),
  ('b0000000-0000-4000-8000-000000000002', 'B 家媽媽'),
  ('c0000000-0000-4000-8000-000000000001', '效能測試帳號')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.families (id, name, created_by) values
  ('fa000000-0000-4000-8000-000000000001', 'A 家',   'a0000000-0000-4000-8000-000000000001'),
  ('fb000000-0000-4000-8000-000000000001', 'B 家',   'b0000000-0000-4000-8000-000000000001'),
  ('fc000000-0000-4000-8000-000000000001', '效能家', 'c0000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role, can_upload) values
  ('fa000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', 'member', true),
  ('fa000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003', 'viewer', false),
  ('fb000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'member', true);

insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at) values
  ('1a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'LS6-AAA-INVITE', 'member', 'a0000000-0000-4000-8000-000000000001', 3, now() + interval '7 days'),
  ('1b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'LS6-BBB-INVITE', 'member', 'b0000000-0000-4000-8000-000000000001', 3, now() + interval '7 days');

insert into public.children (id, family_id, name, birthday) values
  ('2a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001', '小芽', date '2023-05-01'),
  ('2b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001', '小苗', date '2024-02-14');

insert into public.media (id, family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by) values
  ('3a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000001.jpg',
   'photo', 1048576, now() - interval '2 days', 3024, 4032, 'a0000000-0000-4000-8000-000000000001'),
  ('3a000000-0000-4000-8000-000000000002', 'fa000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001/2026/08/3a000000-0000-4000-8000-000000000002.jpg',
   'photo', 2097152, now() - interval '1 day', 3024, 4032, 'a0000000-0000-4000-8000-000000000002'),
  ('3b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'fb000000-0000-4000-8000-000000000001/2026/08/3b000000-0000-4000-8000-000000000001.jpg',
   'photo', 1048576, now() - interval '3 days', 3024, 4032, 'b0000000-0000-4000-8000-000000000001');

insert into public.albums (id, family_id, title, cover_media_id, created_by) values
  ('4a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'A 家：第一次走路',
   '3a000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001'),
  ('4b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'B 家：滿月',
   '3b000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001');

-- LS-121：child_id 從 albums/diaries 的單一欄位改成連結表，fixtures 的既有標記
-- （A 家相簿/日記掛小芽、B 家相簿/日記掛小苗）改用 album_children/diary_children
-- 表達，語意與搬遷前逐字相同（各自恰好標一個孩子）。
insert into public.album_children (family_id, album_id, child_id) values
  ('fa000000-0000-4000-8000-000000000001', '4a000000-0000-4000-8000-000000000001',
   '2a000000-0000-4000-8000-000000000001'),
  ('fb000000-0000-4000-8000-000000000001', '4b000000-0000-4000-8000-000000000001',
   '2b000000-0000-4000-8000-000000000001');

insert into public.album_media (album_id, media_id, family_id, sort_order) values
  ('4a000000-0000-4000-8000-000000000001', '3a000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001', 0),
  ('4a000000-0000-4000-8000-000000000001', '3a000000-0000-4000-8000-000000000002',
   'fa000000-0000-4000-8000-000000000001', 1),
  ('4b000000-0000-4000-8000-000000000001', '3b000000-0000-4000-8000-000000000001',
   'fb000000-0000-4000-8000-000000000001', 0);

insert into public.diaries (id, family_id, author_id, body, entry_date) values
  ('5a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001',
   '今天小芽自己走了三步。', current_date - 1),
  ('5b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001',
   '小苗滿月了。', current_date - 2);

insert into public.diary_children (family_id, diary_id, child_id) values
  ('fa000000-0000-4000-8000-000000000001', '5a000000-0000-4000-8000-000000000001',
   '2a000000-0000-4000-8000-000000000001'),
  ('fb000000-0000-4000-8000-000000000001', '5b000000-0000-4000-8000-000000000001',
   '2b000000-0000-4000-8000-000000000001');

insert into public.diary_media (diary_id, media_id, family_id, sort_order) values
  ('5a000000-0000-4000-8000-000000000001', '3a000000-0000-4000-8000-000000000001',
   'fa000000-0000-4000-8000-000000000001', 0),
  ('5b000000-0000-4000-8000-000000000001', '3b000000-0000-4000-8000-000000000001',
   'fb000000-0000-4000-8000-000000000001', 0);

insert into public.comments (id, family_id, target_type, target_id, author_id, body) values
  ('6a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'media', '3a000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000003', '好可愛！'),
  ('6b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'media', '3b000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002', '長大了。');

insert into public.reactions (id, family_id, target_type, target_id, user_id) values
  ('7a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'media', '3a000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003'),
  ('7b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'media', '3b000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002');

insert into public.device_tokens (token, user_id) values
  ('ls6-token-a001', 'a0000000-0000-4000-8000-000000000001'),
  ('ls6-token-b001', 'b0000000-0000-4000-8000-000000000001');

insert into public.content_reports (id, family_id, target_type, target_id, reporter_id, reason) values
  ('8a000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'comment', '6a000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000002', '測試用檢舉'),
  ('8b000000-0000-4000-8000-000000000001', 'fb000000-0000-4000-8000-000000000001',
   'comment', '6b000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002', '測試用檢舉');

insert into public.blocked_users (family_id, blocker_id, blocked_id) values
  ('fa000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003'),
  ('fb000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002');

-- 自我檢查：fixtures 本身有沒有建成功（後面每個測試都建立在這上面，這裡錯了後面全部沒有意義）
do $$
declare
  n_a int;
  n_b int;
  n_feed int;
  used bigint;
begin
  select count(*) into n_a from public.family_members
    where family_id = 'fa000000-0000-4000-8000-000000000001';
  select count(*) into n_b from public.family_members
    where family_id = 'fb000000-0000-4000-8000-000000000001';
  if n_a <> 3 or n_b <> 2 then
    raise exception 'FIXTURE FAIL：成員數不對（A=% 期望 3，B=% 期望 2）—— families 的 add_creator_as_owner trigger 可能沒有生效', n_a, n_b;
  end if;

  -- feed_items 完全由 trigger 產生：A 家 1 相簿 + 2 照片 + 1 日記 = 4
  select count(*) into n_feed from public.feed_items
    where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n_feed <> 4 then
    raise exception 'FIXTURE FAIL：A 家 feed_items 應為 4 列，實際 %', n_feed;
  end if;

  -- storage_used_bytes 也完全由 trigger 產生：1 MiB + 2 MiB
  select storage_used_bytes into used from public.families
    where id = 'fa000000-0000-4000-8000-000000000001';
  if used <> 3145728 then
    raise exception 'FIXTURE FAIL：A 家 storage_used_bytes 應為 3145728，實際 %', used;
  end if;

  raise notice 'ok fixtures：A 家 3 位成員 / feed 4 列 / 用量 3145728 bytes，B 家 2 位成員';
end;
$$;

-- ---------------------------------------------------------------------------
-- LS-204 R2（merge-review R1 `a2e9cd1b` B1）：107_album_summaries.sql §6 與
-- 50_rls_plan_no_percall_subquery.sql 共用的 5 萬列同家庭「背景雜訊」media
-- fixture，改用這支函式而不是 psql `\i`/`\ir` 相對 include。
--
-- 原本的做法（R1，已撤銷）：把 insert 抽成 supabase/tests/fixtures/ 底下的
-- 檔案，兩支測試用 `\ir` 各自 include。這在 run.sh 的 docker-exec 連線管道下
-- 會整支中止——那條管道是 `docker exec -i <container> psql ... < "$1"`（見
-- run.sh 檔頭），檔案內容經 stdin 餵給容器內的 psql，psql 執行時沒有「呼叫端
-- 腳本所在目錄」這個概念（`\ir` 的相對路徑解析基準），容器本身也沒有掛載
-- host 上的這份 repo，`\ir fixtures/...` 一律 `No such file or directory`。
-- R1 handoff 誤判為全綠，是因為驗證時手動把 libpq 的 psql 加進了 PATH（改走
-- host psql 那條管道）——這不是本機預設環境：預設 shell 找不到 psql，run.sh
-- 本來就會自動退到 docker-exec 管道（見 run.sh 檔頭「psql 不一定裝在 host 上」
-- 那段），而這正是會踩雷的那條路。R1 那份 fixture 檔頭寫「要驗證這個管道本機
-- 需另外安裝 psql」，前提本身就是錯的——不該要求開發者為了測試通過而改動本機
-- 環境，本機三種連線管道原本就該天生一致。
--
-- 改法：把 insert 包成一支普通（非 temporary）SQL 函式，由本檔（00_fixtures.sql，
-- 每次都會真的 COMMIT，不像其他測試檔跑完就 rollback）建立一次，107／50_ 各自
-- 在自己的交易內呼叫 `select private.ls204_seed_media_perf_noise();`——純 SQL
-- 呼叫，不涉及任何檔案路徑解析，三種連線管道（host psql／SUPABASE_DB_URL／
-- docker exec）天生一致，不會有「哪條路徑能不能被 psql 用戶端看到某個檔案」
-- 這種環境相依的差異。函式建在 private schema：`20260822120300_harden_default_
-- privileges.sql` 已對「現在起新建的函式」下了不分 schema 的全域
-- `alter default privileges revoke execute on functions from public`，本函式
-- 建立時自動不對 anon／authenticated／PUBLIC 開放 EXECUTE（60_default_
-- privileges.sql §2／§3 通掃會驗證這件事仍然成立），不需要另外補一句 revoke；
-- 放 private 而不是 public，是因為 public schema 的每一支函式都要在
-- 60_default_privileges.sql §8 的白名單登記（那是給前端 RPC 用的 API 邊界清單），
-- 這支純粹是測試 fixture 內部工具，不是 API，登記進那份清單會誤導成「這是一支
-- RPC」。`security definer set search_path = ''`：60_default_privileges.sql §9
-- 通掃 schema private「每一支」函式都必須是這個形狀（除非登記在該段的 invoker
-- 例外清單並附理由）——這支函式會寫入 public.media，不是「純 regex／只讀
-- GUC」那種夠格例外的形狀，比照其餘 private 函式一律收斂，不另外登記例外。
-- search_path=''下 `public.media` 已完整 schema-qualify；`generate_series` 是
-- pg_catalog 內建函式，search_path 恆隱含 pg_catalog，不受影響。
create or replace function private.ls204_seed_media_perf_noise()
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.media
    (family_id, storage_path, type, byte_size, taken_at, width, height, uploaded_by, created_at)
  select
    'fc000000-0000-4000-8000-000000000001',
    'fc000000-0000-4000-8000-000000000001/2026/' || lpad((1 + (i % 12))::text, 2, '0') || '/noise-' || i || '.jpg',
    'photo', 1024, now() - (i * interval '1 minute'), 3024, 4032,
    'c0000000-0000-4000-8000-000000000001', now() - (i * interval '1 minute')
    from generate_series(1, 50000) i;
$$;
