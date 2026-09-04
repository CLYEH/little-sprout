-- LS-169 — 寶貝大頭照上傳：擴充 Storage 路徑規約以接受 `{family_id}/avatars/{child_id}.jpg`
--
-- 為什麼需要這支 migration（票文原本寫「不做：Storage policy 變更（既有家庭前綴 policy
-- 涵蓋）」，這個假設經實測是錯的，記錄在這裡供之後對照）：
--
-- `20260823030000_storage_policies.sql` 的 `private.is_media_object_path(text)` 是
-- `media_bucket_insert`／`media_bucket_update` 兩條 policy WITH CHECK 的唯一路徑規約判斷式，
-- 只接受 `{family_id}/{yyyy}/{mm}/{media_id}.{ext}`（或 `_thumb.jpg` 縮圖）這個形狀——
-- `avatars` 字面段落不符合 `[0-9]{4}/(0[1-9]|1[0-2])` 這個 `{yyyy}/{mm}` 規則，票文指定的
-- 頭像路徑 `{family_id}/avatars/{child_id}.jpg` 會被這條 WITH CHECK 直接判為不合規、
-- 整支 INSERT／UPDATE 以 `42501` 被拒。「家庭前綴」只是 policy 眾多條件之一（另一個獨立
-- 分支是 `(storage.foldername(name))[1] in (select ... uploadable_family_ids())`），
-- 家庭前綴對了不代表整條路徑規約也對了——票文的「涵蓋」假設漏看了這一段。
--
-- 修法：`is_media_object_path` 本來就是「這個 bucket 允許寫入的路徑規約」，不是專屬於
-- `media` 表列的判斷式（本身不觸碰任何資料表，純路徑 regex）——頭像不寫 `media` 表，
-- 但一樣是要寫進同一個 `media` bucket 的合法物件，把它併入同一支判斷式的規約（用 `|`
-- 並列兩種合法形狀）比另開一支新函式＋改兩條 policy 的 WITH CHECK 更小的變更面：
-- 兩條 policy 完全不必動，`60_default_privileges.sql` 的允許清單也不必新增條目
-- （函式名稱與簽章都沒變，`create or replace function` 不影響既有的 grant）。
--
-- 新形狀：`{family_id}/avatars/{child_id}.jpg`——`family_id`／`child_id` 一律小寫正規形
-- UUID（同既有規約的理由：`children.id` 由 Postgres 產生，`uuid::text` 輸出恆為小寫；
-- Swift 端 `UUID().uuidString` 一樣要 `.lowercased()`，同 docs/API.md §6 既有客戶端契約）；
-- 副檔名固定 `.jpg`（票文 Scope 1：512×512 JPEG，不像原圖／縮圖那樣要接受多種格式）。
-- 家庭歸屬與上傳權判斷完全沿用既有 policy 的 `uploadable_family_ids()`／`owned_family_ids()`
-- 分支——那兩段本來就跟路徑形狀無關，不需要為頭像另開規則。

create or replace function private.is_media_object_path(p_name text)
returns boolean
language sql
immutable
as $$
  select p_name ~ (
    -- {family_id}
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
    || '('
    ||   -- 既有形狀：{yyyy}/{mm}/{media_id}.{ext}，或縮圖 {media_id}_thumb.jpg
         '[0-9]{4}/(0[1-9]|1[0-2])/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
         || '(_thumb\.jpg|\.(jpg|jpeg|png|heic|heif|mp4|mov))'
    ||   -- LS-169 新增：avatars/{child_id}.jpg（不寫 media 表，恆為 .jpg）
    '|avatars/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg'
    || ')$'
  );
$$;

-- `create or replace function`（簽章不變）不會重置既有的 grant，這裡照既有慣例明寫一次，
-- 讓本檔自己的保證不建立在「20260823030000 那支還在」這件事上（同該檔的既有理由）。
revoke execute on function private.is_media_object_path(text) from public;
grant execute on function private.is_media_object_path(text) to authenticated;
