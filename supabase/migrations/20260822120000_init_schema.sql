-- LS-6 — Little Sprout 基礎 schema（docs/PLAN.md §5 資料模型、§9-A、§10-A）
--
-- 設計原則（全部來自 PLAN，不是這裡發明的）：
--   1. 每張內容表都帶 family_id，family 是唯一的隔離邊界（§4-3、§5 RLS 段）。
--   2. 內容表一律 soft delete（deleted_at）——長輩誤刪照片是高機率事件，硬刪沒有救援路徑。
--   3. 照片與相簿／日記的掛載關係用連結表，media 只負責檔案本身（§5「掛載關係為什麼拆成連結表」）。
--   4. families.storage_quota_bytes / storage_used_bytes 是公開上架的硬防線（§10-A）。
--   5. content_reports / blocked_users 是 App Store UGC 規定的承載表（§9-A1），表與 RLS 第一天就建。
--
-- RLS policy、trigger 分別在後續兩個 migration。

-- ---------------------------------------------------------------------------
-- private schema：RLS 用的 SECURITY DEFINER 輔助函式住這裡（§5「不要直接內嵌子查詢」）
-- ---------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- 列舉型別
-- ---------------------------------------------------------------------------
create type public.family_role as enum ('owner', 'member', 'viewer');
create type public.media_type as enum ('photo', 'video');
create type public.feed_kind as enum ('album', 'media', 'diary');

-- comments / reactions / content_reports 的多型關聯 target（§5：Postgres 無法對它下外鍵，
-- 孤兒資料靠應用層或定期清理處理——這個代價是已知且被接受的）。
-- 'comment' 是為了 content_reports：UGC 規定要能檢舉留言，不只是照片。
create type public.content_target_type as enum ('album', 'media', 'diary', 'comment');

create type public.report_status as enum ('pending', 'resolved', 'dismissed');
create type public.device_platform as enum ('ios');

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 50),
  avatar_url text
);

comment on table public.profiles is 'auth.users 的公開側資料；帳號刪除（§9-A2）時隨 auth.users 一起 cascade。';

-- ---------------------------------------------------------------------------
-- families
-- ---------------------------------------------------------------------------
create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  -- 刻意可為 NULL + on delete set null：建立者刪帳號時家庭與所有人的照片必須存活
  -- （§9-A2：唯一 Owner 刪帳號會讓整個家庭懸空，解法是多 Owner + 轉移，不是連坐刪除）
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  -- §10-A：公開上架後任何人都能註冊並上傳到你付費的 bucket，沒有上限就是把信用卡交給陌生人。
  -- 預設 5 GiB（§10-A 建議 2–5GB）；storage_used_bytes 由 media 的 trigger 維護，使用者無寫入權限。
  storage_quota_bytes bigint not null default 5368709120 check (storage_quota_bytes >= 0),
  storage_used_bytes bigint not null default 0 check (storage_used_bytes >= 0)
);

comment on column public.families.storage_used_bytes is
  '由 media 的 statement-level trigger 維護（private.media_storage_sync）；authenticated 沒有此欄位的 UPDATE 權限。';

-- ---------------------------------------------------------------------------
-- family_members —— 權限模型的核心（§3）
-- ---------------------------------------------------------------------------
create table public.family_members (
  family_id uuid not null references public.families (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.family_role not null default 'member',
  -- §3：Member 預設可上傳（祖父母也會拍照），可由 Owner 逐人關閉，不是整個家庭一刀切
  can_upload boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

-- private.family_ids() 的主要存取路徑：以 user_id 查所屬 family
create index family_members_user_idx on public.family_members (user_id);

-- ---------------------------------------------------------------------------
-- invites —— max_uses/expires_at 是隱私要求不是便利功能（§5）
-- ---------------------------------------------------------------------------
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  code text not null unique check (char_length(code) between 6 and 64),
  role public.family_role not null default 'member',
  created_by uuid references public.profiles (id) on delete set null,
  max_uses integer not null default 1 check (max_uses > 0),
  used_count integer not null default 0 check (used_count >= 0),
  -- NOT NULL：可無限期重用的邀請碼一旦外流就是陌生人進家庭，與「私密」定位直接衝突
  expires_at timestamptz not null,
  constraint invites_uses_within_max check (used_count <= max_uses)
);

create index invites_family_idx on public.invites (family_id);

-- ---------------------------------------------------------------------------
-- children
-- ---------------------------------------------------------------------------
create table public.children (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 50),
  -- NOT NULL：孩子檔案的核心用途是年齡標記（Phase 1-3 驗證條件），沒有生日的孩子檔案沒有意義
  birthday date not null,
  avatar_url text,
  created_at timestamptz not null default now(),
  -- 讓 albums / diaries 能以 (family_id, child_id) 複合外鍵綁定同家庭的孩子
  constraint children_family_id_id_key unique (family_id, id)
);

create index children_family_idx on public.children (family_id);

-- ---------------------------------------------------------------------------
-- media —— 只負責檔案本身，不知道自己掛在哪個相簿／日記
-- ---------------------------------------------------------------------------
create table public.media (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  -- §5 檔案路徑規約：{family_id}/{yyyy}/{mm}/{media_id}.{ext}，yyyy/mm 取上傳時間。
  -- CHECK 強制 family_id 前綴：未來 S3 sync 到 NAS 是整個前綴搬走，前綴錯了搬不動；
  -- 同時也是 Storage RLS 會依賴的性質。
  storage_path text not null unique,
  type public.media_type not null,
  -- PLAN §5 的欄位清單沒有列 byte_size，但 §5 最後一條要求 storage_used_bytes 由 trigger 維護，
  -- 沒有每筆檔案大小就無法維護那個計數，因此這是被約束推導出來的必要欄位。
  byte_size bigint not null check (byte_size >= 0),
  taken_at timestamptz,
  width integer not null check (width > 0),
  height integer not null check (height > 0),
  uploaded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint media_storage_path_family_prefix check (storage_path like family_id::text || '/%'),
  constraint media_family_id_id_key unique (family_id, id)
);

-- 主查詢：某家庭最新的未刪除照片。id 當 tie-breaker——一次上傳 50 張會拿到同一個 now()，
-- 只用 created_at 做 keyset 分頁會漏項／跳項。
create index media_family_created_idx
  on public.media (family_id, created_at desc, id desc)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- albums
-- ---------------------------------------------------------------------------
create table public.albums (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  child_id uuid,
  title text not null check (char_length(btrim(title)) between 1 and 100),
  cover_media_id uuid,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint albums_family_id_id_key unique (family_id, id),
  -- 複合外鍵：封面與孩子都必須屬於同一個 family。RLS 已經擋住跨 family 讀取，
  -- 但那只是「看不到」；這裡讓跨 family 的關聯根本建不起來（DB 保證 > 應用層保證）。
  constraint albums_child_same_family_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete set null (child_id),
  constraint albums_cover_same_family_fkey foreign key (family_id, cover_media_id)
    references public.media (family_id, id) on delete set null (cover_media_id)
);

create index albums_family_created_idx on public.albums (family_id, created_at desc)
  where deleted_at is null;
create index albums_child_idx on public.albums (family_id, child_id);
create index albums_cover_idx on public.albums (family_id, cover_media_id);

-- ---------------------------------------------------------------------------
-- album_media —— 連結表
-- family_id 是刻意加的（PLAN §5 RLS 段：「所有內容表都帶 family_id」）：
--   1. policy 可以直接檢查 family_id，不必為了判斷歸屬去 join albums（那才會變成 per-row 子查詢）
--   2. 兩條複合外鍵讓「A 家的相簿掛 B 家的照片」在 DB 層就建不起來
-- ---------------------------------------------------------------------------
create table public.album_media (
  album_id uuid not null,
  media_id uuid not null,
  family_id uuid not null references public.families (id) on delete cascade,
  sort_order integer not null default 0,
  primary key (album_id, media_id),
  constraint album_media_album_fkey foreign key (family_id, album_id)
    references public.albums (family_id, id) on delete cascade,
  constraint album_media_media_fkey foreign key (family_id, media_id)
    references public.media (family_id, id) on delete cascade
);

create index album_media_album_idx on public.album_media (family_id, album_id, sort_order);
create index album_media_media_idx on public.album_media (family_id, media_id);

-- ---------------------------------------------------------------------------
-- diaries
-- ---------------------------------------------------------------------------
create table public.diaries (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  child_id uuid,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(btrim(body)) between 1 and 20000),
  entry_date date not null default current_date,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint diaries_family_id_id_key unique (family_id, id),
  constraint diaries_child_same_family_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete set null (child_id)
);

create index diaries_family_entry_idx on public.diaries (family_id, entry_date desc, id desc)
  where deleted_at is null;
create index diaries_child_idx on public.diaries (family_id, child_id);

-- ---------------------------------------------------------------------------
-- diary_media —— 同 album_media
-- ---------------------------------------------------------------------------
create table public.diary_media (
  diary_id uuid not null,
  media_id uuid not null,
  family_id uuid not null references public.families (id) on delete cascade,
  sort_order integer not null default 0,
  primary key (diary_id, media_id),
  constraint diary_media_diary_fkey foreign key (family_id, diary_id)
    references public.diaries (family_id, id) on delete cascade,
  constraint diary_media_media_fkey foreign key (family_id, media_id)
    references public.media (family_id, id) on delete cascade
);

create index diary_media_diary_idx on public.diary_media (family_id, diary_id, sort_order);
create index diary_media_media_idx on public.diary_media (family_id, media_id);

-- ---------------------------------------------------------------------------
-- comments / reactions —— 多型關聯（§5 已知代價：無法下外鍵）
-- ---------------------------------------------------------------------------
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  target_type public.content_target_type not null,
  target_id uuid not null,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index comments_target_idx on public.comments (family_id, target_type, target_id, created_at)
  where deleted_at is null;

create table public.reactions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  target_type public.content_target_type not null,
  target_id uuid not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- PLAN §5 指定的 UNIQUE：一個人對同一個目標只能有一顆愛心（target_id 是 uuid，全域唯一）
  constraint reactions_target_user_key unique (target_type, target_id, user_id)
);

create index reactions_target_idx on public.reactions (family_id, target_type, target_id);

-- ---------------------------------------------------------------------------
-- device_tokens —— 推播（§4）
-- ---------------------------------------------------------------------------
create table public.device_tokens (
  -- token 當 PK：同一支裝置換帳號登入時 token 必須只對應到最後一個使用者，
  -- 否則舊帳號會繼續收到別人的家庭通知。
  token text primary key check (char_length(token) between 1 and 512),
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform public.device_platform not null default 'ios',
  updated_at timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);

-- ---------------------------------------------------------------------------
-- feed_items —— 時間軸（§5「為什麼第一天就要有」），由 trigger 維護，使用者只讀
-- ---------------------------------------------------------------------------
create table public.feed_items (
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.feed_kind not null,
  ref_id uuid not null,
  occurred_at timestamptz not null,
  primary key (kind, ref_id)
);

-- keyset 分頁：WHERE family_id = $1 AND (occurred_at, ref_id) < ($2, $3) ORDER BY ... DESC LIMIT n
create index feed_items_family_occurred_idx
  on public.feed_items (family_id, occurred_at desc, ref_id desc);

comment on table public.feed_items is
  '由 albums/media/diaries 的 statement-level trigger 維護；soft delete 的內容不會出現在這裡。';

-- ---------------------------------------------------------------------------
-- content_reports / blocked_users —— App Store UGC 三件套的承載表（§9-A1、§10-B）
-- ---------------------------------------------------------------------------
create table public.content_reports (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  target_type public.content_target_type not null,
  target_id uuid not null,
  reporter_id uuid references public.profiles (id) on delete set null,
  reason text not null check (char_length(btrim(reason)) between 1 and 1000),
  status public.report_status not null default 'pending',
  created_at timestamptz not null default now()
);

create index content_reports_family_idx on public.content_reports (family_id, status, created_at desc);
-- §10-B：被檢舉的很可能就是該家庭的 Owner，所以平台方（service_role / Dashboard）
-- 必須能跨家庭看待處理清單，不能只靠 Owner 自理。
create index content_reports_pending_idx on public.content_reports (created_at desc)
  where status = 'pending';

create table public.blocked_users (
  family_id uuid not null references public.families (id) on delete cascade,
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (family_id, blocker_id, blocked_id),
  constraint blocked_users_not_self check (blocker_id <> blocked_id)
);

-- ---------------------------------------------------------------------------
-- 權限（RLS 之外的第二層）
--
-- Supabase 的 default privileges 會自動把 ALL 授給 anon / authenticated。
-- 這裡全部收回再逐表發放，理由有二：
--   1. anon（未登入）對本 app 的任何資料都不該有 table 權限——RLS policy 是 `to authenticated`，
--      但少一層 grant 就少一種被 policy 疏漏波及的可能。
--   2. families.storage_used_bytes / storage_quota_bytes 是成本防線（§10-A）。RLS 無法限制欄位，
--      所以用 column-level grant：使用者只能改 name，額度與用量只有 trigger（definer）與
--      service_role 能動。否則「硬防線」只要一句 UPDATE 就沒了。
--      同理，INSERT 與 media 的 UPDATE 也必須逐欄列舉——防線只擋 UPDATE 不擋 INSERT，
--      或只擋 families 不擋 media，都等於沒擋。
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;

-- 上面那句只收得回「已經存在的表」。Supabase 的 default privileges 對未來新增的表一樣是全開，
-- 所以下一個 migration 建的表會在 CREATE 完成的瞬間就對 anon/authenticated 全開，
-- 而新表預設沒有 RLS——等於整張表對未登入者可讀可寫，直到有人記得補 grant。收斂掉。
--
-- 【部署檢查項】ALTER DEFAULT PRIVILEGES 只影響「由指定角色建立」的物件。本機／CI 的
-- migration 由 postgres 執行，這一句就夠；真實 Supabase 專案上 public schema 的 default
-- privileges 可能掛在 postgres 或 supabase_admin 名下，上線時要用 `\ddp` 覆核，
-- 必要時對每個 owner 角色各下一次 `alter default privileges for role <role> ...`。
alter default privileges in schema public revoke all on tables from anon, authenticated;

grant select, insert, update on public.profiles to authenticated;

grant select on public.families to authenticated;
-- INSERT 只給這兩欄：全欄位 INSERT 等於讓任何人在「建立家庭」的那一刻自帶 storage_quota_bytes，
-- §10-A 的成本防線只擋 UPDATE 是擋不住的（實測：自帶 1 TiB 額度可以建立成功）。
-- id / created_at / 額度 / 用量一律走預設值。
grant insert (name, created_by) on public.families to authenticated;
grant update (name) on public.families to authenticated;

grant select, insert, update, delete on public.family_members to authenticated;
grant select, insert, update, delete on public.invites to authenticated;
grant select, insert, update, delete on public.children to authenticated;

grant select, insert, delete on public.media to authenticated;
-- UPDATE 同樣逐欄列舉：全欄位 UPDATE 讓上傳者把自己照片的 byte_size 改成 0，
-- 一句 UPDATE 就能把整個家庭的用量歸零（storage_used_bytes 是 trigger 依 byte_size 算出來的）。
-- 允許改的只有這四欄：deleted_at（soft delete 與還原）、taken_at 與 width/height（EXIF 補正）。
-- family_id / storage_path / uploaded_by / byte_size 一旦可改，歸屬、檔案位置與用量都不可信。
grant update (taken_at, deleted_at, width, height) on public.media to authenticated;

grant select, insert, update, delete on public.albums to authenticated;
grant select, insert, update, delete on public.album_media to authenticated;
grant select, insert, update, delete on public.diaries to authenticated;
grant select, insert, update, delete on public.diary_media to authenticated;
grant select, insert, update, delete on public.comments to authenticated;
grant select, insert, delete on public.reactions to authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select on public.feed_items to authenticated;

grant select, insert on public.content_reports to authenticated;
-- 只給 status：檢舉的內容（reason／reporter_id／target）是稽核紀錄，處理者不該改得動它，
-- 否則「被檢舉的 owner 自己處理檢舉」可以連檢舉理由一起改掉。
grant update (status) on public.content_reports to authenticated;

grant select, insert, delete on public.blocked_users to authenticated;
