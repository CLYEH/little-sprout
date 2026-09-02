-- LS-121（LS-21 後端）— 日記／相簿多寶貝標記：diary_children／album_children 連結表，
-- RPC 改陣列參數，時間軸多寶貝篩選，LS044 守門搬家
--
-- 背景：LS-119 核可頁回饋第 8 點「發日記的時候應該要能同時標記多個寶貝」，追問後裁決
-- 「日記與相簿一起改」。這推翻 LS-47 四題之⑤「發佈單選歸屬、可不指定」——自本票起
-- 「不指定」仍保留、「指定」可多個（1 篇日記／1 本相簿可對到 0～N 個孩子）。
--
-- **BREAKING**：`diaries.child_id`／`albums.child_id`／`feed_items.child_id` 三欄
-- 移除（資料先搬進連結表，同一支 migration、可重跑）；`create_diary_entry`／
-- `update_diary_entry` 簽章從單一 `p_child_id uuid` 改成 `p_child_ids uuid[]`——
-- 舊簽名函式直接 DROP，不留兩個 overload（iOS 端目前沒有日記／相簿呼叫端，LS-21
-- 實作票尚未開，這裡不需要相容期）。
--
-- ---------------------------------------------------------------------------
-- 0. 設計選擇：時間軸篩選走「trigger 維護的扁平表」而不是「查詢時 join 連結表」
--
-- 票面要求二擇一並附 EXPLAIN：
--   (a) 直接 join diary_children／album_children
--   (b) 新增由 trigger 維護的 feed_item_children (family_id, kind, ref_id, child_id,
--       occurred_at)，保持 keyset 走索引
--
-- 選 (b)。理由（EXPLAIN 證據見 PR handoff／supabase/tests/50_rls_plan_no_percall_subquery.sql）：
--   1. LS-48 F1 的教訓完全適用：get_family_timeline 的 child 篩選必須是「等值比對
--      走專屬索引」的靜態查詢，不能是「join 之後再篩」——join 一本多對多連結表再依
--      keyset 排序分頁，规划器很難把「join 後排序」下推成「先用複合索引取好序、
--      再逐列決定要不要留」，這正是 F1 當時實測過的退化模式（Bitmap／Seq Scan＋
--      顯式 Sort）。(b) 讓「篩 child」這個操作維持成單一等值條件（`fc.child_id =
--      p_child_id`），跟 (family_id, child_id, occurred_at desc, ref_id desc) 這個
--      複合索引的形狀完全對齊，跟 LS-48 已經驗證過的 feed_items 本身查詢是同一種
--      索引策略，不是新發明。
--   2. keyset 分頁「不得跳項」的保證：(a) 的 join 版本在「一篇日記標了兩個孩子」時，
--      不篩 child 的分頁若不小心 join 進連結表會產生重複列（同一篇日記因為 join
--      到兩個 child 各出現一次），需要額外 DISTINCT／GROUP BY 去重，這類去重操作
--      在 keyset 分頁下容易在分頁邊界產生跳項或重複項（去重與 LIMIT 的交互作用
--      是已知的分頁地雷）。(b) 讓「全部」與「篩 child」分別各自查一張只回傳「一個
--      項目對一個 child」的扁平表（`feed_items` 本身、或 `feed_item_children`），
--      兩者的列數本來就與最終要回傳的列數一致，不需要去重。
--   3. 與既有 `feed_items` 本身「trigger 維護的扁平表，避免查詢時 join」設計同一個
--      理由（見 20260822120000_init_schema.sql 對 feed_items 的註解），架構一致，
--      不是分裂出第二套設計。
--
-- 代價：多一張 trigger 維護的表、多幾支 trigger 函式；`feed_items.child_id`
-- （LS-48 加的單一欄位）隨本票移除——一個項目現在可以對到 0～N 個孩子，單一欄位的
-- 資料模型已經不成立，見第 4 段。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. 連結表：diary_children／album_children／feed_item_children
--
-- diary_children／album_children 比照 album_media／diary_media 的既有慣例：
-- 自帶 family_id（policy 不必 join 回母表判斷歸屬），複合外鍵綁同一家庭
-- （比照 diaries_child_same_family_fkey），on delete cascade（診／相簿被硬刪、
-- 或孩子檔案未來若真的開放硬刪，連結列一併清掉）。
--
-- 與 album_media／diary_media 不同：這兩張表對 authenticated 收斂 RPC-only
-- （直接 INSERT/UPDATE/DELETE 不給任何 grant——不需要 LS-48 那種「先開放、後收斂」
-- 的 ALTER POLICY 手法，因為是全新的表，一開始就不開放）；讀取（SELECT）對同家庭
-- 任一角色開放（含 viewer）。
--
-- 索引：PK (diary_id, child_id) 本身就是「查一篇日記標了哪些孩子」的索引（diary_id
-- 是 PK 最前面那欄）；另外兩個複合索引服務兩個方向的外鍵反查（65_fk_reverse_index.sql
-- 要求每個外鍵的參照欄位集合都要能對上某個索引最前面幾欄）—— (family_id, diary_id)
-- 服務「同一家庭的診被刪除／搬遷」的反查，(family_id, child_id) 服務「同一家庭的
-- 孩子被刪除」的反查，也是票面明確要求的「反向索引 (family_id, child_id, …)」。
-- ---------------------------------------------------------------------------

create table public.diary_children (
  family_id uuid not null references public.families (id) on delete cascade,
  diary_id uuid not null,
  child_id uuid not null,
  primary key (diary_id, child_id),
  constraint diary_children_diary_fkey foreign key (family_id, diary_id)
    references public.diaries (family_id, id) on delete cascade,
  constraint diary_children_child_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade
);

create index diary_children_family_diary_idx on public.diary_children (family_id, diary_id);
create index diary_children_family_child_idx on public.diary_children (family_id, child_id);

comment on table public.diary_children is
  '日記 ↔ 孩子多對多標記（LS-121，取代 20260822120000_init_schema.sql 原本的
  diaries.child_id 單一欄位）。INSERT／DELETE 唯一路徑是 public.create_diary_entry() /
  public.update_diary_entry()（SECURITY DEFINER，繞過本表的 grant 收斂）；authenticated
  沒有直接 INSERT/UPDATE/DELETE 的 grant，只有 SELECT（同家庭任一角色，含 viewer）。
  沒有 UPDATE 語意——「改標記」是同一交易內先 DELETE 多的、再 INSERT 少的（見兩支
  RPC），不是對既有列做 UPDATE。';

create table public.album_children (
  family_id uuid not null references public.families (id) on delete cascade,
  album_id uuid not null,
  child_id uuid not null,
  primary key (album_id, child_id),
  constraint album_children_album_fkey foreign key (family_id, album_id)
    references public.albums (family_id, id) on delete cascade,
  constraint album_children_child_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade
);

create index album_children_family_album_idx on public.album_children (family_id, album_id);
create index album_children_family_child_idx on public.album_children (family_id, child_id);

comment on table public.album_children is
  '相簿 ↔ 孩子多對多標記（LS-121，取代 albums.child_id 單一欄位）。唯一寫入路徑是
  public.set_album_children()（SECURITY DEFINER）；authenticated 沒有直接 INSERT/
  UPDATE/DELETE 的 grant，只有 SELECT（同家庭任一角色）。相簿本身仍是建立者/owner
  直接 .insert() 建立（未變，見 docs/API.md §2）——建立時不能在同一句 INSERT 帶
  child_id 了（欄位已移除），要標記孩子須緊接著呼叫 set_album_children()。';

-- feed_item_children：get_family_timeline 的 child 篩選查詢引擎（見第 0 段選擇 (b)）。
-- 完全由 trigger 維護（比照 feed_items 自己的「唯讀、trigger 維護」慣例），
-- authenticated 只有 SELECT，沒有任何寫入 grant。
--
-- PK (kind, ref_id, child_id)：前兩欄 (kind, ref_id) 剛好對上 FK1
-- (kind, ref_id) → feed_items(kind, ref_id) 的參照欄位集合，兼作那支外鍵的反向索引。
create table public.feed_item_children (
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.feed_kind not null,
  ref_id uuid not null,
  child_id uuid not null,
  occurred_at timestamptz not null,
  primary key (kind, ref_id, child_id),
  constraint feed_item_children_feed_items_fkey foreign key (kind, ref_id)
    references public.feed_items (kind, ref_id) on delete cascade,
  constraint feed_item_children_child_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade
);

-- 主查詢索引：get_family_timeline 篩 child 時的 keyset 分頁走這個（同 feed_items 自己的
-- family_occurred_idx／舊 family_child_occurred_idx 是同一種索引形狀），也兼作 FK2
-- (family_id, child_id) → children(family_id, id) 的反向索引。
create index feed_item_children_family_child_occurred_idx
  on public.feed_item_children (family_id, child_id, occurred_at desc, ref_id desc);

comment on table public.feed_item_children is
  'get_family_timeline 篩 child 用的扁平查詢表（LS-121）：一個時間軸項目標記 N 個孩子
  就有 N 列，每列 (kind, ref_id, child_id) 各自可以被等值篩選、走
  feed_item_children_family_child_occurred_idx 做 keyset 分頁——不篩 child 的查詢
  完全不碰這張表，走 feed_items 本身（一個項目一列，天然不重複）。完全由
  private.feed_sync_diary_children() / private.feed_sync_album_children() /
  private.feed_sync_diaries() / private.feed_sync_albums() 四支 trigger 函式維護，
  authenticated 沒有任何寫入 grant。';

alter table public.diary_children enable row level security;
alter table public.album_children enable row level security;
alter table public.feed_item_children enable row level security;

create policy diary_children_select on public.diary_children for select to authenticated
  using (family_id in (select private.family_ids()));
create policy album_children_select on public.album_children for select to authenticated
  using (family_id in (select private.family_ids()));
create policy feed_item_children_select on public.feed_item_children for select to authenticated
  using (family_id in (select private.family_ids()));

-- 沒有 INSERT/UPDATE/DELETE policy——RLS 預設對沒有匹配 policy 的操作一律拒絕；
-- 唯一寫入路徑是下面幾支 SECURITY DEFINER 函式（trigger／RPC），它們以表擁有者身分
-- 執行，繞過 RLS，不受這裡「沒有寫入 policy」的限制。
grant select on public.diary_children to authenticated;
grant select on public.album_children to authenticated;
grant select on public.feed_item_children to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 資料搬遷：把既有 diaries.child_id／albums.child_id 的值搬進連結表
--
-- 只搬非 NULL 的值（NULL＝原本就不指定，連結表沒有對應列本來就是「不指定」的正確
-- 表達）。這一步刻意排在第 6 段的新 BEFORE INSERT LS044 trigger 之前執行——正式站
-- 可能存在「日記／相簿的 child_id 指向一個當下已經軟刪的孩子」這種既有資料（§8
-- 語意：軟刪不影響既有內容），若先建好 LS044 trigger 才搬資料，這些既有關聯會被
-- 那支「擋新內容」的 trigger 誤傷擋下——LS044 管的是「未來要不要允許新歸屬」，不是
-- 「這批本來就存在的歷史關聯要不要保留」，兩者不能共用同一次搬遷時序。
--
-- on conflict do nothing：可重跑（同一支 migration 若因故被要求重新套用同一段
-- SQL，不會因為列已存在而報 23505）。
-- ---------------------------------------------------------------------------

insert into public.diary_children (family_id, diary_id, child_id)
select family_id, id, child_id from public.diaries where child_id is not null
on conflict (diary_id, child_id) do nothing;

insert into public.album_children (family_id, album_id, child_id)
select family_id, id, child_id from public.albums where child_id is not null
on conflict (album_id, child_id) do nothing;

-- 既有 feed_items 列（已經存在的、非軟刪的日記／相簿）也要展開回 feed_item_children，
-- 讓上線當下既有資料的「篩 child」查詢立刻正確，不必等下一次編輯才被動補上。
insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
select f.family_id, f.kind, f.ref_id, dc.child_id, f.occurred_at
  from public.feed_items f
  join public.diary_children dc on dc.diary_id = f.ref_id
 where f.kind = 'diary'
on conflict do nothing;

insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
select f.family_id, f.kind, f.ref_id, ac.child_id, f.occurred_at
  from public.feed_items f
  join public.album_children ac on ac.album_id = f.ref_id
 where f.kind = 'album'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 3. 移除舊的 diaries_child_not_deleted／albums_child_not_deleted trigger
--
-- 這兩支 trigger（20260825030000_children_write_path_and_soft_delete.sql 第 4 段）
-- 檢查的是 diaries.child_id／albums.child_id 這兩個即將被移除的欄位——DROP COLUMN
-- 不會自動清掉這兩支 trigger（trigger 函式本體是 plpgsql 文字，不是欄位層級的
-- catalog 依賴，Postgres 不會幫忙級聯），必須先手動 DROP，否則欄位一消失，下一次
-- 任何 INSERT/UPDATE 打中這兩張表就會直接因為「NEW.child_id 不存在」而噴錯。
-- private.enforce_child_not_deleted() 函式本身不用動——它只依賴 NEW.child_id／
-- OLD.child_id 這兩個欄位名，第 6 段會把它原封不動掛到新的連結表 BEFORE INSERT
-- trigger 上，同一支函式重用，不是重寫。
-- ---------------------------------------------------------------------------

drop trigger diaries_child_not_deleted on public.diaries;
drop trigger albums_child_not_deleted on public.albums;

-- ---------------------------------------------------------------------------
-- 4. BREAKING：移除 diaries.child_id／albums.child_id／feed_items.child_id 三欄
--
-- 「一篇日記／一本相簿最多對應一個孩子」（N:1）的資料模型自本票起不成立，改成
-- 連結表表達的多對多——單一欄位與連結表是兩套互斥的真相來源，不留兩套（票面原文：
-- 「不留兩套真相」）。DROP COLUMN 會自動一併移除：
--   - diaries_child_same_family_fkey／albums_child_same_family_fkey（複合外鍵，
--     直接參照被刪的欄位）
--   - diaries_child_idx／albums_child_idx（索引，鍵欄位含被刪的欄位）
--   - feed_items_child_same_family_fkey／feed_items_family_child_occurred_idx
--     （同理）
--   - albums 欄位級 grant 清單裡的 child_id 這一項（20260825040000_deletion_
--     attribution.sql 的 `grant update (title, child_id, cover_media_id)`——
--     title／cover_media_id 兩欄的 grant 不受影響，只有 child_id 這一項的 ACL
--     隨欄位一起消失）
-- 都不需要另外下 DROP INDEX／DROP CONSTRAINT／REVOKE——這是 PostgreSQL 對
-- DROP COLUMN 的標準行為，不是本票發明的捷徑。
-- ---------------------------------------------------------------------------

alter table public.diaries drop column child_id;
alter table public.albums drop column child_id;
alter table public.feed_items drop column child_id;

-- ---------------------------------------------------------------------------
-- 5. LS044 守門搬家：BEFORE INSERT trigger 掛到連結表上
--
-- 重用同一支 private.enforce_child_not_deleted()（20260825030000_children_write_
-- path_and_soft_delete.sql 第 4 段定義，本票不 CREATE OR REPLACE、原封不動）——
-- 函式邏輯「INSERT 恆檢查；UPDATE 只在 child_id 真的變動時檢查」對連結表天然適用：
-- 連結表沒有 UPDATE 語意（改標記是先刪後插，見第 7 段），這裡只掛 BEFORE INSERT，
-- tg_op 恆為 'INSERT'，函式內 `tg_op = 'INSERT' or ...` 這個 OR 條件的左側恆真，
-- 不會走到右側去讀一個在純 INSERT 情境下根本不存在的 OLD 記錄。
--
-- 錯誤碼延續 LS044（意義不變：「寶貝已移除，無法歸屬新內容」），docs/API.md §5
-- 的「由哪支 RPC／哪個路徑觸發」欄同步改寫成連結表路徑。
-- ---------------------------------------------------------------------------

create trigger diary_children_not_deleted
  before insert on public.diary_children
  for each row execute function private.enforce_child_not_deleted();

create trigger album_children_not_deleted
  before insert on public.album_children
  for each row execute function private.enforce_child_not_deleted();

-- ---------------------------------------------------------------------------
-- 6. feed_item_children 維護：連結表異動時的 AFTER INSERT/DELETE trigger
--
-- 兩張連結表各一個函式（比照 feed_sync_albums／feed_sync_diaries／feed_sync_media
-- 既有慣例：不同表共用一個泛型 trigger 函式是 plpgsql 語句計畫快取的已知地雷，
-- 20260822120100_triggers.sql 第 100 行附近已經記過這個理由，不重複）。
--
-- INSERT 方向：只在「這個項目當下確實在 feed_items 裡（未被軟刪）」時才展開寫入
-- feed_item_children——若日記／相簿當下是軟刪狀態，feed_items 沒有它的列，這裡的
-- join 自然是 0 列，no-op；等它被還原時，由第 8 段改寫過的 feed_sync_diaries／
-- feed_sync_albums 的 INSERT 分支重新展開（那時 diary_children／album_children
-- 的既有列在軟刪期間完全沒被動過，見 §8「軟刪不連動」，重新展開的資料是對的）。
--
-- 這支 trigger 也是 create_diary_entry／update_diary_entry／set_album_children
-- 三支 RPC 唯一需要「順便」處理 feed_item_children 的地方——RPC 本身完全不碰這張
-- 表，只管連結表本身的刪多補少，feed_item_children 的同步是這裡跟第 8 段兩處
-- trigger 聯手做完，RPC 不需要知道這張表存在。
--
-- DELETE 方向：直接刪掉對應的一列。沒有靠 FK CASCADE（feed_item_children 對
-- feed_items 的 FK 只在「整個項目從 feed_items 消失」時才會級聯，這裡是「項目還在，
-- 只是某個孩子的標記被拿掉」，兩種情況不同，FK 級聯管不到後者，必須顯式 DELETE）。
-- ---------------------------------------------------------------------------

create or replace function private.feed_sync_diary_children()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.feed_item_children
     where kind = 'diary' and ref_id = old.diary_id and child_id = old.child_id;
    return old;
  end if;

  insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
  select f.family_id, 'diary', f.ref_id, new.child_id, f.occurred_at
    from public.feed_items f
   where f.kind = 'diary' and f.ref_id = new.diary_id
  on conflict do nothing;
  return new;
end;
$$;

create trigger diary_children_feed_insert after insert on public.diary_children
  for each row execute function private.feed_sync_diary_children();
create trigger diary_children_feed_delete after delete on public.diary_children
  for each row execute function private.feed_sync_diary_children();

create or replace function private.feed_sync_album_children()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.feed_item_children
     where kind = 'album' and ref_id = old.album_id and child_id = old.child_id;
    return old;
  end if;

  insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
  select f.family_id, 'album', f.ref_id, new.child_id, f.occurred_at
    from public.feed_items f
   where f.kind = 'album' and f.ref_id = new.album_id
  on conflict do nothing;
  return new;
end;
$$;

create trigger album_children_feed_insert after insert on public.album_children
  for each row execute function private.feed_sync_album_children();
create trigger album_children_feed_delete after delete on public.album_children
  for each row execute function private.feed_sync_album_children();

-- ---------------------------------------------------------------------------
-- 7. feed_sync_diaries／feed_sync_albums：拿掉 child_id 欄位，加回還原時的重新展開
--
-- 用 CREATE OR REPLACE 覆寫函式本體（同 20260824010000_diaries_write_path_and_
-- timeline.sql 第 3 段的既有手法：函式簽章不變，掛著它的三支 statement-level
-- trigger 不需要重建，不改動 20260822120100_triggers.sql 這個舊檔案本身）。
--
-- 兩處變動：
--   a) INSERT INTO feed_items 的欄位清單拿掉 child_id（表本身已經沒有這欄，第 4 段）。
--   b) 新增一段 INSERT INTO feed_item_children，把 new_rows 對應的 diary_children／
--      album_children 現況展開進去——這是「還原」（deleted_at 設回 NULL）的必要
--      補充：還原觸發這支函式的 INSERT 分支，此時 diary_children／album_children
--      的既有標記在軟刪期間完全沒被動過（§8「軟刪不連動」），必須主動重新展開，
--      不能指望第 6 段的連結表 trigger（那支只在連結表本身被 INSERT/DELETE 時
--      觸發，還原動作根本沒有動到連結表）。新建立時這裡的 join 天生是 0 列
--      （create_diary_entry／set_album_children 的呼叫順序是先插入 diaries／
--      albums 本體，diary_children／album_children 是下一句才插入的，這個分支
--      執行的當下連結表還沒有對應列可 join），no-op，交給第 6 段的連結表 trigger
--      接手——兩處 trigger 分工，不是重複。
-- ---------------------------------------------------------------------------

create or replace function private.feed_sync_albums()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'album' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'album', n.id, n.created_at
        from new_rows n where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'album', n.id, ac.child_id, n.created_at
        from new_rows n
        join public.album_children ac on ac.album_id = n.id
       where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

create or replace function private.feed_sync_diaries()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    delete from public.feed_items f using old_rows o
      where f.kind = 'diary' and f.ref_id = o.id;
  end if;
  if tg_op <> 'DELETE' then
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
      select n.family_id, 'diary', n.id, (n.entry_date::timestamp at time zone 'utc')
        from new_rows n where n.deleted_at is null;

    insert into public.feed_item_children (family_id, kind, ref_id, child_id, occurred_at)
      select n.family_id, 'diary', n.id, dc.child_id, (n.entry_date::timestamp at time zone 'utc')
        from new_rows n
        join public.diary_children dc on dc.diary_id = n.id
       where n.deleted_at is null
    on conflict do nothing;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. RPC：create_diary_entry／update_diary_entry 改陣列參數（BREAKING），
--    新增 set_album_children
--
-- 舊簽名直接 DROP，不留兩個 overload（票面明確要求；iOS 端目前沒有日記／相簿呼叫端，
-- 不需要相容期，見檔頭）。
--
-- 陣列語意（三支 RPC 共用同一套規則）：
--   - p_child_ids 為 NULL 或空陣列＝不指定（清空既有標記，若原本有的話）。
--   - 非 NULL 且非空＝全覆蓋：目前的標記集合會被替換成這個陣列去重、過濾 NULL
--     元素之後的集合——多的刪掉、少的補上（「刪多補少」），不是逐一累加或相減。
--   - 陣列裡的重複值／NULL 元素靜默去重／過濾，不是錯誤（呼叫端可能傳一個沒特別
--     處理過的使用者勾選結果，不需要自己先 dedupe）。
--   - 陣列裡任何一個 child_id 跨家庭（不屬於這篇日記／這本相簿所屬的家庭）→ 23503
--     （複合外鍵 diary_children_child_fkey／album_children_child_fkey 擋下，跟舊版
--     單一欄位時代的複合外鍵擋法一致，不是新錯誤碼）。
--   - 陣列裡任何一個 child_id 指向已軟刪的孩子 → LS044（連結表的 BEFORE INSERT
--     trigger，見第 5 段）。
--
-- 併發語意（票面「race 測試」要求）：update_diary_entry／set_album_children 開頭
-- 沿用既有的 `select ... for update` 鎖住目標列（診／相簿本體）——這把鎖原本是為了
-- 保護「是否已軟刪除」「是否仍是 owner/member」這些授權判斷不讀到過期快照，本票
-- 延伸它的涵蓋範圍：整組「刪多補少」的連結表覆蓋動作，都排在拿到這把鎖之後才執行、
-- 在同一個交易內完成——兩個連線同時對同一篇日記呼叫 update_diary_entry（各自想要
-- 不同的最終集合），後動的那個會被這把鎖擋住，直到先動的那個 commit；後動的那個
-- 接著才真正執行自己的「刪多補少」，讀到的是先動那次已經 commit 的最終狀態，寫出
-- 的是自己完整的、覆蓋後的集合——終態一定是「後 commit 那次呼叫的完整集合」，不會
-- 是兩次呼叫的合併（回歸測試見 supabase/tests/concurrency/diary_children_race_*.sql）。
-- ---------------------------------------------------------------------------

drop function public.create_diary_entry(uuid, uuid, text, date);
drop function public.update_diary_entry(uuid, text, date, uuid);

create or replace function public.create_diary_entry(
  p_family_id uuid,
  p_child_ids uuid[],
  p_body text,
  p_entry_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法建立日記' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid and m.role in ('owner', 'member')
  ) then
    raise exception '只有該家庭的成員（owner／member）能寫日記' using errcode = '42501';
  end if;

  insert into public.diaries (family_id, author_id, body, entry_date)
  values (p_family_id, v_uid, p_body, coalesce(p_entry_date, current_date))
  returning id into v_id;

  insert into public.diary_children (family_id, diary_id, child_id)
  select p_family_id, v_id, u.child_id
    from (select distinct x as child_id from unnest(p_child_ids) as x where x is not null) u;

  return v_id;
end;
$$;

revoke execute on function public.create_diary_entry(uuid, uuid[], text, date) from public, anon;
grant execute on function public.create_diary_entry(uuid, uuid[], text, date) to authenticated;

create or replace function public.update_diary_entry(
  p_diary_id uuid,
  p_body text,
  p_entry_date date,
  p_child_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_diary public.diaries%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法編輯日記' using errcode = '42501';
  end if;

  select d.* into v_diary from public.diaries d where d.id = p_diary_id for update;

  if not found then
    raise exception '日記不存在' using errcode = 'LS020';
  end if;

  if v_diary.author_id is distinct from v_uid
     or not exists (
       select 1 from public.family_members m
        where m.family_id = v_diary.family_id and m.user_id = v_uid and m.role in ('owner', 'member')
     ) then
    raise exception '只有仍是該家庭 owner/member 的原作者能編輯這篇日記' using errcode = 'LS021';
  end if;

  if v_diary.deleted_at is not null then
    raise exception '這篇日記已被移除，請先還原後再編輯' using errcode = 'LS020';
  end if;

  update public.diaries d
     set body = p_body,
         entry_date = coalesce(p_entry_date, current_date)
   where d.id = p_diary_id;

  -- 刪多補少（LS-121）：在已經鎖住 v_diary 這一列之後才動連結表，見檔頭第 8 段
  -- 的併發語意說明。
  delete from public.diary_children dc
   where dc.diary_id = p_diary_id
     and not exists (select 1 from unnest(p_child_ids) as x where x = dc.child_id);

  insert into public.diary_children (family_id, diary_id, child_id)
  select v_diary.family_id, p_diary_id, u.child_id
    from (select distinct x as child_id from unnest(p_child_ids) as x where x is not null) u
   where not exists (
     select 1 from public.diary_children dc
      where dc.diary_id = p_diary_id and dc.child_id = u.child_id
   );
end;
$$;

revoke execute on function public.update_diary_entry(uuid, text, date, uuid[]) from public, anon;
grant execute on function public.update_diary_entry(uuid, text, date, uuid[]) to authenticated;

-- set_album_children：albums 的 hybrid 模式下，內容欄位（title／cover_media_id）
-- 仍是建立者直接 .update()（未變，見 docs/API.md §3）；child_id 移到連結表之後，
-- 這是唯一能碰 album_children 的路徑。授權門檻沿用 albums_update policy 的建立者
-- 分支（仍是該家庭 owner/member 的建立者本人）——跟「改內容」同一種性質的操作，
-- 不是 set_album_deleted 那種「owner 也能對別人的相簿做」的移除／還原權限（見
-- docs/API.md §3「為什麼 albums／comments／diaries 曾經、現在用了不同的寫入模型」
-- 對 albums hybrid 模式的既有說明——owner 對別人相簿的內容沒有直接改寫的路徑，
-- 標記孩子屬於「內容」不是「移除」，同一條界線延伸過來）。
--
-- 錯誤碼：相簿不存在沿用既有的 LS023（跟 set_album_deleted 共用同一個碼，語意
-- 一致：「相簿不存在」）；「不是建立者、或雖是建立者但已不是該家庭 owner/member」
-- 是本票新開的 LS045（LS040-044 已被 LS-66 用滿，見 docs/API.md §5）。
create or replace function public.set_album_children(
  p_album_id uuid,
  p_child_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_album public.albums%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法設定相簿的寶貝標記' using errcode = '42501';
  end if;

  select a.* into v_album from public.albums a where a.id = p_album_id for update;

  if not found then
    raise exception '相簿不存在' using errcode = 'LS023';
  end if;

  if v_album.created_by is distinct from v_uid
     or not exists (
       select 1 from public.family_members m
        where m.family_id = v_album.family_id and m.user_id = v_uid and m.role in ('owner', 'member')
     ) then
    raise exception '只有仍是該家庭 owner/member 的建立者能設定這本相簿的寶貝標記' using errcode = 'LS045';
  end if;

  delete from public.album_children ac
   where ac.album_id = p_album_id
     and not exists (select 1 from unnest(p_child_ids) as x where x = ac.child_id);

  insert into public.album_children (family_id, album_id, child_id)
  select v_album.family_id, p_album_id, u.child_id
    from (select distinct x as child_id from unnest(p_child_ids) as x where x is not null) u
   where not exists (
     select 1 from public.album_children ac
      where ac.album_id = p_album_id and ac.child_id = u.child_id
   );
end;
$$;

revoke execute on function public.set_album_children(uuid, uuid[]) from public, anon;
grant execute on function public.set_album_children(uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. get_family_timeline：回傳欄 child_id uuid 改成 child_ids uuid[]，
--    p_child_id 篩選改走 feed_item_children（見第 0 段）
--
-- 回傳型別變了（RETURNS TABLE 的欄位型別，不是參數簽章），Postgres 不允許
-- CREATE OR REPLACE 改變既有函式的回傳型別，必須先 DROP。參數簽章
-- (uuid, uuid, timestamptz, uuid, integer) 不變，docs/API.md §9 機械對帳清單
-- 的 RPC 簽章那一行因此不用改；但回傳形狀對呼叫端是真實的破壞性變更，PR body
-- 的 BREAKING 段落與 API.md §4 對這支函式的文字說明都要點出來。
--
-- 四條靜態分支維持 LS-48 F1 立下的規則不變（不篩 child／篩 child × 無游標／有
-- 游標）：不篩走 feed_items，篩 child 走 feed_item_children，兩者都在各自的
-- 子查詢裡先完成「篩選＋排序＋LIMIT」，才在外層對每一列做一次 child_ids 的
-- array_agg 查詢——這是 list_comments（20260825020000_comments_reactions_
-- notifications.sql）已經驗證過的既有模式（「先子查詢篩選排序 LIMIT，才 LEFT
-- JOIN 拿額外欄位」），這裡把 LEFT JOIN 換成一個依 kind 分流的 correlated
-- 純量子查詢（child_ids 是陣列聚合，不是單一列的 JOIN，形狀不同但時機一致：
-- 一律在 LIMIT 已經生效、只剩 ≤p_limit 列之後才執行，不會在篩選＋排序之前
-- 對整個 feed_items／feed_item_children 做任何形式的 join）。media 類項目兩個
-- CASE 分支都不匹配，落到 ELSE（隱式 NULL），最終 coalesce 成 '{}'::uuid[]，
-- 符合「media 類恆空陣列」（票面第 4 點）。
-- ---------------------------------------------------------------------------

drop function public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer);

create or replace function public.get_family_timeline(
  p_family_id uuid,
  p_child_id uuid default null,
  p_cursor_occurred_at timestamptz default null,
  p_cursor_ref_id uuid default null,
  p_limit integer default 20
)
returns table (
  kind public.feed_kind,
  ref_id uuid,
  occurred_at timestamptz,
  child_ids uuid[]
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
  end if;

  if p_child_id is null then
    if p_cursor_occurred_at is null then
      return query
        select p.kind, p.ref_id, p.occurred_at,
               coalesce(
                 case p.kind
                   when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                        from public.diary_children dc where dc.diary_id = p.ref_id)
                   when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                        from public.album_children ac where ac.album_id = p.ref_id)
                 end,
                 '{}'::uuid[]
               ) as child_ids
          from (
            select f.kind, f.ref_id, f.occurred_at
              from public.feed_items f
             where f.family_id = p_family_id
             order by f.occurred_at desc, f.ref_id desc
             limit v_limit
          ) p
         order by p.occurred_at desc, p.ref_id desc;
    else
      return query
        select p.kind, p.ref_id, p.occurred_at,
               coalesce(
                 case p.kind
                   when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                        from public.diary_children dc where dc.diary_id = p.ref_id)
                   when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                        from public.album_children ac where ac.album_id = p.ref_id)
                 end,
                 '{}'::uuid[]
               ) as child_ids
          from (
            select f.kind, f.ref_id, f.occurred_at
              from public.feed_items f
             where f.family_id = p_family_id
               and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
             order by f.occurred_at desc, f.ref_id desc
             limit v_limit
          ) p
         order by p.occurred_at desc, p.ref_id desc;
    end if;
  else
    if p_cursor_occurred_at is null then
      return query
        select p.kind, p.ref_id, p.occurred_at,
               coalesce(
                 case p.kind
                   when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                        from public.diary_children dc where dc.diary_id = p.ref_id)
                   when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                        from public.album_children ac where ac.album_id = p.ref_id)
                 end,
                 '{}'::uuid[]
               ) as child_ids
          from (
            select fc.kind, fc.ref_id, fc.occurred_at
              from public.feed_item_children fc
             where fc.family_id = p_family_id
               and fc.child_id = p_child_id
             order by fc.occurred_at desc, fc.ref_id desc
             limit v_limit
          ) p
         order by p.occurred_at desc, p.ref_id desc;
    else
      return query
        select p.kind, p.ref_id, p.occurred_at,
               coalesce(
                 case p.kind
                   when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                        from public.diary_children dc where dc.diary_id = p.ref_id)
                   when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                        from public.album_children ac where ac.album_id = p.ref_id)
                 end,
                 '{}'::uuid[]
               ) as child_ids
          from (
            select fc.kind, fc.ref_id, fc.occurred_at
              from public.feed_item_children fc
             where fc.family_id = p_family_id
               and fc.child_id = p_child_id
               and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
             order by fc.occurred_at desc, fc.ref_id desc
             limit v_limit
          ) p
         order by p.occurred_at desc, p.ref_id desc;
    end if;
  end if;
end;
$$;

revoke execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  to authenticated;
