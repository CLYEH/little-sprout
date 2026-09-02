-- LS-128（LS-20 後端）— media 縮圖欄：thumb_path／thumb_width／thumb_height
--
-- 背景（票面）：LS-126 merge-review R1（comment 16ecf7c1）指出時間軸列表載全尺寸
-- 原圖，違反 PLAN §7「列表只載縮圖」的 egress 防線；public.media 當時沒有縮圖
-- 欄位，Storage 批次簽 URL 也沒有 transform，這件事在 UI 票內修不了。本票只補
-- 後端：schema 欄位＋讀寫契約文件＋測試。iOS 端（上傳同步產生縮圖、列表改讀
-- thumb_path）是本票落地後另開的 ui 小修票，不在本票範圍——orchestrator
-- 2026-09-02 18:15 comment 明文解除對 LS-125／LS-126 的 blockedBy，理由是本票
-- 與那兩張 iOS 票的 PR 無檔案交集。
--
-- 非破壞性：只 ADD COLUMN（皆 nullable）＋ADD CONSTRAINT CHECK／UNIQUE，不改、
-- 不刪任何既有欄位／policy／函式——scripts/gates/migration-breaking-check.sh 的
-- D1-D4（DROP／TRUNCATE／DISABLE RLS／ALTER TYPE）與 B1-B6（policy／REVOKE／
-- 既有函式 OR REPLACE／RENAME／SET SCHEMA）皆不命中，PR body 不需要
-- DESTRUCTIVE-APPROVED 核可標記。
--
-- 路徑規約（docs/PLAN.md §5、docs/API.md §6）：{family_id}/{yyyy}/{mm}/
-- {media_id}_thumb.jpg——20260823030000_storage_policies.sql 的
-- private.is_media_object_path() 早就接受這個尾綴（該檔第 2 段的判斷式最後一段
-- `(_thumb\.jpg|\.(jpg|jpeg|png|heic|heif|mp4|mov))$`），supabase/tests/
-- 90_storage_policies.sql 第 859 段也已經拿 `_thumb.jpg`／`_thumb.png` 正負案例
-- 釘住這支函式。因此 Storage 側 RLS 完全不用改：本票只是把「DB 也知道這張照片
-- 有沒有縮圖、縮圖存在哪個路徑」補上，讀取端才能查表決定簽哪一個路徑，不必用
-- 字串拼接猜。跨家庭讀不到（含 thumb 欄位）由既有 media_select policy 的
-- family_id 判準自動涵蓋（row-level，不是 column-level）——見
-- supabase/tests/98_media_thumbnails.sql 第 2 段的自證測試。
--
-- 為什麼 CHECK 而不是 trigger：跟既有 media_storage_path_family_prefix
-- （20260822120000_init_schema.sql）同一個判準、同一種寫法——storage_path 前綴
-- 已經是 CHECK，thumb_path 沒有理由換一種機制，維持同一張表內的一致性。
--
-- thumb_path 也給 UNIQUE：比照 storage_path 的既有理由（避免兩列指到同一個
-- Storage 物件）。NULL 不受 UNIQUE 約束（Postgres 對 UNIQUE 的 NULL 語意是
-- 「兩個 NULL 不視為相等」），既有／過渡期沒有縮圖的列可以同時是 NULL，互不衝突。
--
-- thumb_width／thumb_height 比照原始 width／height 的「> 0」CHECK，但允許 NULL
-- （縮圖還沒補上時兩者皆空）；額外加一條「thumb_path／thumb_width／thumb_height
-- 三者同為 NULL 或同為非 NULL」的一致性 CHECK——這不是無中生有的潔癖：沒有這條，
-- 「thumb_path 有值但 thumb_width 是 NULL」這種半殘缺狀態會通過寫入，讀取端拿到
-- 縮圖路徑卻沒有尺寸可以用來排版（避免 layout shift），沒有機械防線會擋住。
--
-- 不做（票面「不做」段）：不回填既有資料；不做 Storage image transform；不改
-- media 的 UPDATE 欄位級 grant——thumb_* 三欄比照 storage_path／byte_size／
-- family_id／uploaded_by 的既有慣例，一旦透過 INSERT 寫入即不可再改（immutable）。
-- 上傳流程契約是「原檔＋縮圖都先 PUT 進 Storage，成功後才一次 INSERT 整列
-- media」（docs/API.md §3「上傳流程順序」），不存在「先建 media 列、之後才補上
-- 縮圖」的合法路徑，因此不需要 UPDATE 欄位級 grant——
-- 20260822120000_init_schema.sql 那句
-- `grant select, insert, delete on public.media to authenticated` 是全欄位授權，
-- 已經涵蓋新欄位的 INSERT，本檔不新增任何 grant。

alter table public.media
  add column thumb_path text,
  add column thumb_width integer,
  add column thumb_height integer;

alter table public.media
  add constraint media_thumb_path_family_prefix
    check (thumb_path is null or thumb_path like family_id::text || '/%'),
  add constraint media_thumb_path_key
    unique (thumb_path),
  add constraint media_thumb_width_positive
    check (thumb_width is null or thumb_width > 0),
  add constraint media_thumb_height_positive
    check (thumb_height is null or thumb_height > 0),
  add constraint media_thumb_dimensions_consistency
    check (
      (thumb_path is null) = (thumb_width is null)
      and (thumb_path is null) = (thumb_height is null)
    );

comment on column public.media.thumb_path is
  '縮圖物件路徑（docs/API.md §6：{family_id}/{yyyy}/{mm}/{media_id}_thumb.jpg），
  nullable——既有列與縮圖產生失敗的列由讀取端退回原圖 storage_path（過渡，見
  docs/API.md §4）。上傳端於原檔＋縮圖皆成功 PUT 進 Storage 後隨 media 列一次
  INSERT 寫入，之後不可變（無 UPDATE 欄位級 grant，同 storage_path，LS-128）。';

comment on column public.media.thumb_width is
  '縮圖寬度（px）。與 thumb_path／thumb_height 同為 NULL 或同為非 NULL
  （media_thumb_dimensions_consistency，LS-128）。';

comment on column public.media.thumb_height is
  '縮圖高度（px）。同 thumb_width。';
