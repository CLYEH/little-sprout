-- LS-134（LS-20 後端）— media 影片時長欄：duration_seconds
--
-- 背景（票面）：LS-130 handoff（2026-09-03）指出列表改讀 thumb_path 後，影片卡的
-- 「影片 M:SS」徽章因 AVURLAsset.load(.duration) 拿到的是縮圖 JPEG 而失敗，只剩
-- 「影片」文字；LS-119 核可稿的規格是固定 12pt 的「影片 M:SS」，必須恢復。若要在
-- 列表階段保留徽章又不簽全尺寸原圖，時長必須是可查表的欄位，而不是靠 client 對
-- 縮圖檔案做媒體解碼——DB 補這一欄。
--
-- 非破壞性：只 ADD COLUMN（nullable）＋ADD CONSTRAINT CHECK，不改、不刪任何既有
-- 欄位／policy／函式——scripts/gates/migration-breaking-check.sh 的 D1-D4 與
-- B1-B6 皆不命中，PR body 不需要 DESTRUCTIVE-APPROVED 核可標記。
--
-- 為什麼不加 kind 相依約束（票面「不做」段）：直覺會想加一條「type = 'video' 時
-- duration_seconds 必填、type = 'photo' 時必須是 NULL」的一致性 CHECK（比照
-- LS-128 thumb_* 三欄互相一致的做法）。但這裡不能比照——thumb_* 三欄是同一次
-- migration 新增、當下資料庫沒有任何既有列用得到它們；duration_seconds 是對
-- 「既有 media 表」加欄，既有的 video 列（LS-20 上線以來已上傳的影片）在這支
-- migration 套用當下全部是 duration_seconds IS NULL，若同時加上「video 必填」的
-- CHECK 會讓既有列違反約束、migration 直接失敗。影片必填、照片留空是 API.md 對
-- 上傳端（LS-135）的契約義務，不是資料庫可以現在就機械驗證的不變量——之後若要補
-- 這條約束，需要先回填既有 video 列的 duration_seconds（另立 migration，不在本票
-- 範圍）。
--
-- CHECK(> 0) 而不是 >= 0：0 秒的影片不是合法媒體（沒有畫面可播放），比照既有
-- width／height／byte_size 皆為正數的既有慣例（width/height CHECK > 0，
-- 20260822120000_init_schema.sql）。整數秒、裁切後長度向上取整——見 API.md §3
-- 「影片時長量測與寫入」。
--
-- 不加 UPDATE 欄位級 grant：比照 thumb_path／storage_path／byte_size／family_id／
-- uploaded_by 的既有慣例（20260902101842_media_thumb_path.sql）——上傳流程契約是
-- 「量測時長＋PUT 進 Storage 皆完成後才一次 INSERT 整列 media」（docs/API.md §3
-- 「上傳流程順序」），不存在「先建 media 列、之後才補時長」的合法路徑，因此不需要
-- UPDATE 欄位級 grant。20260822120000_init_schema.sql 那句
-- `grant select, insert, delete on public.media to authenticated;` 是全欄位授權，
-- 已經涵蓋新欄位的 INSERT，本檔不新增任何 grant；既有的
-- `grant update (taken_at, deleted_at, width, height) on public.media to
-- authenticated;` 逐欄列舉不含 duration_seconds，本檔也不動它。

alter table public.media
  add column duration_seconds integer;

alter table public.media
  add constraint media_duration_seconds_positive
    check (duration_seconds is null or duration_seconds > 0);

comment on column public.media.duration_seconds is
  '影片時長（整數秒，向上取整）。type = ''photo'' 時應為 NULL；type = ''video'' 時
  由上傳端以 AVAsset 量測寫入（裁切過的影片以裁切後長度為準）——此契約由 docs/API.md
  §3 與上傳端負責，DB 只驗「有值時必須 > 0」（media_duration_seconds_positive），
  不驗與 type 的相依關係（既有 video 列在本 migration 套用當下皆為 NULL，見檔頭）。
  一旦隨 INSERT 寫入即不可再 UPDATE（無欄位級 grant，同 storage_path，LS-134）。';
