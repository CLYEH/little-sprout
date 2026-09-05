-- LS-200（LS-20 後端）— album_summaries：security invoker view，供相簿 tab 列表
-- 一次讀取 visible_media_count／latest_media_id／latest_thumb_path／
-- latest_storage_path／cover_thumb_path／cover_storage_path。
--
-- 背景（LS-165 merge-review R2 `fdcb3602` m3，R3 實測）：iOS 相簿列表原本用
-- PostgREST 內嵌 aggregate `album_media(count)` 取張數——那數的是 `album_media`
-- 連結列本身，不是「使用者依 RLS 看得到的照片數」：已被軟刪（`media.deleted_at`
-- 非 NULL 且呼叫者不是上傳者，見 `20260904080921_media_select_hide_deleted.sql`
-- 的 `media_select` policy）、或 LS-155 刪帳號後 `uploaded_by` 被 FK
-- `on delete set null` 清空的 media，仍會被算進「N 張」。LS-165 R2 也實測過幾種
-- PostgREST embed+aggregate 語法（`album_media(media!inner(id),count)` 拿到
-- `42803` GROUP BY 錯誤；`album_media!inner(media!inner(count))` 拿到的是「每個
-- album_media 各自一個 count」而不是單一總數）——這個形狀的計數（依賴巢狀可見性
-- 過濾後再彙總）不是 PostgREST 內嵌查詢語法能表達的，需要後端另開 view 或 RPC。
-- 這支 view 就是那個後端物件。
--
-- 為什麼是 security_invoker 而不是（預設的）security_definer 語意：
--   這是本專案第一支 view，沒有既有 view 可循，因此把選擇的理由完整交代：
--   view 預設以「建立者」的身分執行內部查詢，等同繞過查詢者的 RLS——對一張要
--   「只算使用者依 RLS 看得到的 media」的摘要表，那正是我們不要的行為（會變成
--   definer 身分把所有家庭、所有軟刪列都算進去，等於重新引入本票要修的那個
--   bug，只是換了個物件）。`security_invoker = true`（PostgreSQL 15+／Supabase
--   支援）讓 view 內部對 `albums`／`album_media`／`media` 的存取，一律套用「呼叫
--   這個 view 的使用者」的權限與 RLS policy，效果等同使用者自己直接下這三段
--   查詢——`albums_select`／`album_media_select`／`media_select` 三條既有 policy
--   （family 隔離、軟刪過濾、上傳者例外）不必在 view 定義裡重複寫一次判準，
--   也不會因為兩處各寫一份而未來改 policy 忘了同步改 view。
--
-- 為什麼用 LATERAL 聚合而不是 view 裡兩個獨立的 correlated 子查詢（count 一次、
-- latest 排序一次）：兩個獨立子查詢等於對每一本相簿的 `album_media JOIN media`
-- 做兩次一模一樣的走訪；改成單一 LATERAL 子查詢，count(*) 與「依 created_at 挑
-- 最新一張的 thumb_path」在同一次走訪、同一組列上一起算出來（`array_agg(...
-- order by ...)[1]` 是「排序後取第一個」的標準寫法，PostgreSQL 聚合函式沒有
-- 內建的 first()/last()）。`left join lateral ... on true`：這個子查詢是
-- 「無 GROUP BY 的聚合」，天生保證恰好一列（0 筆命中時 count(*)=0、
-- array_agg(...)=NULL，不是 0 列），LEFT JOIN 在這裡等同 INNER JOIN，選 LEFT
-- 是防禦性寫法——之後若有人把子查詢改成帶 GROUP BY 的形狀（可能回傳 0 列），
-- 不會因此讓整本相簿從 view 裡消失。
--
-- R2（merge-review R1 N2，裁定併入本票——view 尚未進正式站，現在補免再開一支
-- migration）：多帶 `latest_media_id`／`latest_storage_path`／`cover_storage_path`
-- 三欄。理由：`docs/API.md` §6 既有的簽名策略是「`thumb_path` 為 NULL 時（既有
-- 資料、縮圖產生失敗的過渡列）退回 `storage_path` 簽名 URL」——iOS 端要落實這個
-- 退回規則，需要同時拿得到 thumb 與原圖兩種路徑，只給 `*_thumb_path` 會讓退回
-- 判斷做不下去。`latest_media_id` 一併附上，供呼叫端需要時反查該筆 media 的其他
-- 欄位（例如 `duration_seconds`，若最新一張是影片）。三欄沿用同一組
-- `array_agg(... order by ...)[1]`／cover 的 LEFT JOIN 邏輯，可見性判準不變。
--
-- 索引核對（不需要新增索引，EXPLAIN 證據見 supabase/tests/107_album_summaries.sql
-- 第 6 段與本機執行後留存的 supabase/tests/evidence/album_summaries_explain.txt，
-- 該目錄 gitignore、CI 以 artifact 留存，比照 LS-6 RLS plan 證據的既有慣例）：
--   - `am.album_id = a.id`：album_media 的 PRIMARY KEY (album_id, media_id) 前綴
--     即 album_id，足夠支撐這個等式查找。
--   - `m.id = am.media_id`／cover 子查詢的 `cm.id = a.cover_media_id`：media 的
--     PRIMARY KEY (id) 直接支撐兩者，皆為單列點查找。
--   - 排序鍵 `m.created_at`：走訪的是「單一相簿底下已連結的 media」這個小集合
--     （不是整張 media 表），LATERAL 子查詢內對這個小集合排序不需要額外索引；
--     `media_family_created_idx` 是給整表依 family 分頁用的既有索引，跟這裡的
--     用途不同，不衝突也不需要調整。
--
-- Grant：只開 authenticated 的 SELECT；anon 沒有——這支 view 沒有任何寫入語意
-- （沒有 INSERT/UPDATE/DELETE grant，也沒有可更新 view 需要的 WITH CHECK
-- OPTION），比照既有慣例只開讀。`20260822120000_init_schema.sql` 已對 public
-- schema 下了 `alter default privileges ... revoke all on tables from anon,
-- authenticated`（PostgreSQL 的 ALTER DEFAULT PRIVILEGES ON TABLES 同時涵蓋
-- view／foreign table，不是只管一般表），因此這支新 view 建立時對 anon／
-- authenticated 預設就是零權限，不需要另外 REVOKE，只需要明確 GRANT
-- authenticated 要用到的那一份。
--
-- 不是 DESTRUCTIVE／BREAKING：全篇只有 CREATE VIEW（新物件）＋GRANT（新
-- 授權），沒有 DROP／ALTER 既有物件、沒有 REVOKE 既有角色的權限，PR body 不需要
-- DESTRUCTIVE-APPROVED 核可標記，也不需要 BREAKING: 段落。

create view public.album_summaries
  with (security_invoker = true)
as
select
  a.*,
  coalesce(v.visible_media_count, 0) as visible_media_count,
  v.latest_media_id,
  v.latest_thumb_path,
  v.latest_storage_path,
  cm.thumb_path as cover_thumb_path,
  cm.storage_path as cover_storage_path
from public.albums a
left join lateral (
  select
    count(*) as visible_media_count,
    (array_agg(m.id order by m.created_at desc, m.id desc))[1] as latest_media_id,
    (array_agg(m.thumb_path order by m.created_at desc, m.id desc))[1] as latest_thumb_path,
    (array_agg(m.storage_path order by m.created_at desc, m.id desc))[1] as latest_storage_path
  from public.album_media am
  join public.media m on m.id = am.media_id
  where am.album_id = a.id
) v on true
left join public.media cm on cm.id = a.cover_media_id;

comment on view public.album_summaries is
  'LS-200：相簿摘要（security_invoker=true）——visible_media_count／
  latest_media_id／latest_thumb_path／latest_storage_path／cover_thumb_path／
  cover_storage_path 只算呼叫者依 RLS 看得到的 media（albums_select／
  album_media_select／media_select 逐使用者生效，跨家庭隔離、軟刪過濾、上傳者
  例外皆沿用既有 policy，view 本身不重複判準）。取代 client 端 `album_media(count)`
  內嵌 aggregate 的連結列計數口徑（LS-165 R2），見 docs/API.md §3
  「albums / diaries」。`*_storage_path` 兩欄是 `*_thumb_path` 為 NULL 時
  （既有資料、縮圖產生失敗的過渡列）的退回來源，見 docs/API.md §6 既有的
  簽名策略。**注意：本 view 的欄位集合於 `CREATE VIEW` 當下由 `albums.*`
  展開凍結——之後對 `albums` 的 `ADD COLUMN` 不會自動出現在這裡，需要用同一份
  `CREATE OR REPLACE VIEW` 文字重建才會補上新欄位（PostgreSQL 對 view 的 `*`
  展開語意，不是動態解析），見 `supabase/tests/107_album_summaries.sql` 的
  結構斷言（albums 欄位集合 ⊆ album_summaries）。';

grant select on public.album_summaries to authenticated;
