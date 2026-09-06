-- LS-222 —— LS-213 merge-review R2（comment 0e4c0eed）N2／N3 收口：
--
-- N3（minor）：`supabase/functions/purge-storage/index.ts` 原本自帶
-- `MEDIA_OBJECT_PATH_RE`，跟 `private.is_media_object_path()` 不等價（縮圖分支：
-- TS 允許任何既有副檔名、SQL 只認 `.jpg`）——落差區間的物件（例如
-- `{uuid}_thumb.png`）每輪被 `purge_storage_unknown_media_paths()` 判定「無對應
-- 列」，再被 `purge_storage_queue_enqueue_orphans()` 的形狀檢查靜默丟棄，沒有任何
-- 計數回報，永遠不會被回收也永遠不會有人知道。
--
-- 修法：路徑合法性只由 `private.is_media_object_path()` 判定一次——TS 端不再自帶
-- regex，改成呼叫下面第 1 段的新 RPC 取得「合法孤兒路徑」與「形狀不合規路徑」兩個
-- 子集合；第 2 段的新 RPC 讓 `enqueue_orphans` 這一步也回報 dropped 計數（防禦性
-- 重驗——理論上呼叫端傳進來的路徑已經是第 1 段驗過的，這裡的 dropped 正常情況下
-- 應該恆為 0，保留是為了不讓這層防線失去可觀測性）。
--
-- 為什麼是新函式名、不是 `create or replace` 原本兩支：
--   - Postgres 不允許 `create or replace function` 改變既有函式的回傳型別
--     （`purge_storage_unknown_media_paths` 是 `returns text[]`，這裡要多回傳一個
--     `invalid_paths` 子集合，形狀變成 `returns table(...)`；
--     `purge_storage_queue_enqueue_orphans` 是 `returns integer`，這裡要變成
--     `returns table(enqueued integer, dropped integer)`）——硬改只能先 DROP 再
--     CREATE，DROP 屬於 `migration-breaking-check.sh` 的 DESTRUCTIVE 分級，需要
--     使用者本人核可標記，不是這張後續收口票該做的事（票文範圍 4 也明寫「不改既有
--     RPC 簽名」）。
--   - 原本兩支（`purge_storage_unknown_media_paths`／
--     `purge_storage_queue_enqueue_orphans`）維持原樣、不刪除——`index.ts` 從本次
--     起改呼叫下面的新函式，舊函式變成未被呼叫但仍存在的合法簽名，供任何理論上
--     依賴舊回傳型別的呼叫端沿用；`supabase/tests/109_…sql` 對兩支舊函式的既有
--     測試維持不動，繼續驗證它們自己的行為沒有被本票動到。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. public.purge_storage_classify_orphan_paths(p_paths text[])
--    -> table(orphan_paths text[], invalid_paths text[])
--
-- 內部組合既有的 `purge_storage_unknown_media_paths()`（「有沒有對應 media 列」
-- 這件事的單一來源不重複實作）＋`private.is_media_object_path()`（路徑形狀合法性
-- 的單一來源）：先把 `p_paths` 依形狀分成合法／不合法兩堆，只對合法的那堆呼叫
-- `purge_storage_unknown_media_paths()` 取得真正孤兒（沒有 media 列引用）的子集合；
-- 不合法的那堆原樣回傳在 `invalid_paths`，供呼叫端計入 dropped 計數並發 warning，
-- 不再靜默消失。
--
-- 不濾 `deleted_at`（沿用 `purge_storage_unknown_media_paths()` 既有、reviewer 已
-- 驗證過的行為）：30 天救援窗內已軟刪的 media（原圖／縮圖）的路徑仍視為「有對應
-- 列」，只要形狀合法就不會落進 `orphan_paths`。
-- ---------------------------------------------------------------------------
create or replace function public.purge_storage_classify_orphan_paths(p_paths text[])
returns table(orphan_paths text[], invalid_paths text[])
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_valid text[];
begin
  select coalesce(array_agg(path), array[]::text[]) into v_valid
    from unnest(p_paths) as path
   where private.is_media_object_path(path);

  orphan_paths := public.purge_storage_unknown_media_paths(v_valid);
  invalid_paths := coalesce((
    select array_agg(path) from unnest(p_paths) as path
     where not private.is_media_object_path(path)
  ), array[]::text[]);
  return next;
end;
$$;

revoke execute on function public.purge_storage_classify_orphan_paths(text[]) from public, anon;
-- 只從 public／anon 收回，理由同本檔其餘新函式（避免誤觸
-- migration-breaking-check.sh 的 BREAKING 分級——這支函式從建立的第一刻就沒有對
-- authenticated 開放過 EXECUTE）。

comment on function public.purge_storage_classify_orphan_paths(text[]) is
  '`purge-storage` Edge Function（LS-222，收口 LS-213 R2 merge-review N3）用來把一批'
  ' Storage 候選路徑分類成「真正孤兒」（orphan_paths：形狀合法且沒有對應 media 列）'
  ' 與「形狀不合規」（invalid_paths：不符 private.is_media_object_path()，例如'
  ' {uuid}_thumb.png——SQL 只認縮圖 .jpg，TS 端過去自帶較寬鬆的 regex 造成落差）'
  ' 兩個子集合。取代 index.ts 原本的本地 regex 篩選——路徑合法性只有這一個判準'
  '（private.is_media_object_path()），TS 不再自己維護一份。invalid_paths 由呼叫端'
  ' 計入 dropped 計數並發 warning，不再靜默消失。內部組合既有'
  ' purge_storage_unknown_media_paths()，不重複實作「有沒有對應 media 列」的查詢。';

-- ---------------------------------------------------------------------------
-- 2. public.purge_storage_queue_enqueue_orphans_v2(p_bucket_id, p_family_id,
--    p_object_paths) -> table(enqueued integer, dropped integer)
--
-- 與原本 `purge_storage_queue_enqueue_orphans()` 的 SQL 本體完全相同（同樣的
-- 前綴＋形狀防禦性重驗、同樣的 on conflict do nothing），差別只在回傳值：原本只
-- 回傳 `enqueued`（實際新增筆數），這支額外回傳 `dropped`（因前綴不符或形狀不
-- 合規被這一層擋下的筆數）——LS-213 R2 merge-review N3 指出這一層原本會把
-- 「規則落差區間」的路徑靜默丟棄、完全無法觀測；即使上游（第 1 段的
-- classify_orphan_paths）已經先驗過一次形狀，這裡仍保留同一組檢查作為防禦性
-- 重驗，正常情況下 dropped 應恆為 0，非 0 代表呼叫端傳入的路徑跟這支函式自己認定
-- 的規則對不上，值得調查。
-- ---------------------------------------------------------------------------
create or replace function public.purge_storage_queue_enqueue_orphans_v2(
  p_bucket_id text,
  p_family_id uuid,
  p_object_paths text[]
)
returns table(enqueued integer, dropped integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_valid text[];
  v_total integer;
begin
  select coalesce(array_agg(path), array[]::text[]) into v_valid
    from unnest(p_object_paths) as path
   where path like p_family_id::text || '/%'
     and private.is_media_object_path(path);

  insert into public.purge_storage_queue (bucket_id, object_path, family_id, media_id)
  select p_bucket_id, path, p_family_id, null
    from unnest(v_valid) as path
  on conflict (bucket_id, object_path) do nothing;

  get diagnostics enqueued = row_count;

  v_total := coalesce(array_length(p_object_paths, 1), 0);
  dropped := v_total - coalesce(array_length(v_valid, 1), 0);
  return next;
end;
$$;

revoke execute on function public.purge_storage_queue_enqueue_orphans_v2(text, uuid, text[]) from public, anon;
-- 只從 public／anon 收回，理由同上（從建立的第一刻就沒有對 authenticated 開放過
-- EXECUTE，避免誤觸 migration-breaking-check.sh 的 BREAKING 分級）。

comment on function public.purge_storage_queue_enqueue_orphans_v2(text, uuid, text[]) is
  '`purge-storage` Edge Function（LS-222，收口 LS-213 R2 merge-review N3）用來把'
  ' Storage 掃描到、確認過的孤兒物件路徑排入 purge_storage_queue——與原本'
  ' purge_storage_queue_enqueue_orphans() SQL 本體相同（前綴＋形狀防禦性重驗、'
  ' on conflict do nothing 冪等），差別是這支額外回傳 dropped（被這一層擋下的'
  ' 筆數），讓被丟棄的路徑不再靜默消失。回傳型別改變（table(enqueued, dropped)'
  ' 對比舊函式的單一 integer）在 Postgres 下無法用 create or replace 沿用同一個'
  ' 函式名，因此另立新名，原函式維持不動、不刪除。';
