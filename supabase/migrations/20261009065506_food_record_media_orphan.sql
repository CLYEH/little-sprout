-- LS-430（LS-425 C3a 裁決；池 1a684a3a 後半）—— 飲食記錄照片的 media 生命週期。
--
-- C3a：從手機新加進 `child_food_records` 的照片進家庭 `media`，但只在該筆記錄內可見
-- （不自動進相簿／日記）。這讓「記錄刪除／換照片後，舊 media 要被清掉」成為本表的責任，
-- 否則留下 `deleted_at IS NULL`、沒有任何 UI 看得到也刪不掉的活列，永久佔用
-- `families.storage_used_bytes`（LS-213 檔頭同一個問題，只是來源換成飲食記錄）。
--
-- 盤點（票 comment 6bd0003a）——不需要新欄位、不需要 media.origin／purpose：
--   「這張 media 屬於飲食記錄」＝存在 `child_food_records.media_id = media.id`（複合 FK
--   `(family_id, media_id)`，反查索引 `child_food_records_family_media_idx` 已存在）。
--
-- 現況缺口（supabase/tests/126_food_record_media_orphan.sql 先紅證實）：
--   (1) 每日清理 `private.soft_delete_unreferenced_media`（LS-213）的「引用」只認
--       `diary_media`／`album_media`——掛在**有效**飲食記錄上的手機照片，上傳滿 24 小時就被
--       軟刪（活資料被誤清，記錄顯示「照片沒有載入」）。比票文假設的「孤兒殘留」更嚴重。
--   (2) 刪除記錄／換照片／不用照片後，舊 media 沒有任何即時清理。
--
-- 做法（最小變更，兩個部件）：
--   1. 每日清理的引用判定補上「未軟刪的 `child_food_records` 引用」。只算**未軟刪**的記錄：
--      記錄軟刪＝格子退回未嘗試，其照片不該繼續佔用額度（軟刪記錄不會被還原，見
--      `child_food_records` 表註解——要重記是 upsert 新增一筆全新列）。這也是 (c)「上傳
--      >24h 且無任何引用」兜底：client 取消／網路中斷沒能清的未綁定 media，由這支 job 掃掉。
--   2. `child_food_records` 掛一支 row-level AFTER UPDATE trigger：舊 `media_id` 因「換成別張／
--      清成 null／記錄軟刪」而不再被這一列引用時，立即釋放——該 media 沒有任何其他引用
--      （其他有效記錄、日記、相簿）就軟刪（`deleted_at = now()`），走既有 30 天 purge；額度由
--      既有 `private.media_storage_sync()` trigger 回落，這裡不另外處理。
--
-- 為什麼是 trigger 而不是改 RPC：寫入路徑有兩條——`upsert_child_food_record`（換照片，
-- SECURITY INVOKER）與 `delete_child_food_record`（軟刪），而 `child_food_records_update`
-- 欄位級 grant 也允許 `media_id` 被直接 `.update()`。放在 trigger 一處涵蓋全部路徑，且與
-- 本 repo 其餘「AFTER trigger 維護衍生狀態」慣例一致（feed_sync_*）；改 RPC 要改兩支以上
-- 且擋不住直接 UPDATE。
--
-- 為什麼必須 SECURITY DEFINER：`media_update` policy 只認上傳者與 owner，而記錄作者不一定是
-- 該 media 的上傳者（03d 從家庭相簿挑到的是別人上傳的照片）——member 刪自己的記錄時，
-- 對別人上傳的 media 沒有 UPDATE 權（`upsert_child_food_record` 是 SECURITY INVOKER，換照片的
-- trigger 以呼叫者身分執行；`delete_child_food_record` 是 DEFINER，刪除路徑碰巧不受影響）。
-- 測試案 3e 釘住。
--
-- 併發：先對舊 media 取 `FOR UPDATE` 列鎖再判斷引用——另一個交易剛把同一張 media 掛到新記錄
-- （`child_food_records` INSERT 的 FK 檢查會對 media 取 `FOR KEY SHARE`）時，FOR UPDATE 會等它
-- commit，READ COMMITTED 下下一句 SQL 取新快照就看得到那筆新引用而不軟刪。反方向（本交易先
-- 軟刪、另一個交易後掛上）剩一個窄窗：新記錄會指向已軟刪的 media，畫面顯示「照片沒有載入」
-- （既有 04e 失敗態）；03d 挑選器只列未刪列，窗口僅限選取到送出之間，接受。兩條記錄同時被各自
-- 的交易刪掉時各自看到對方仍有效而都不軟刪（write skew）→ 由第 1 段每日清理兜底（不是資料遺失，
-- 只是晚一天清）。
--
-- 觸發條件（trigger WHEN 子句）：只在「這一列原本是有效記錄、原本有照片，且 media_id 變了或這次
-- 把它軟刪」時進函式。FK `on delete set null (media_id)`（media 被硬刪、purge）也會走 UPDATE，
-- 此時舊 media 列已不存在，UPDATE 為 0 列，無害。
--
-- 破壞性：僅 CREATE OR REPLACE FUNCTION＋CREATE TRIGGER，無 DROP／ALTER TABLE／REVOKE。

-- ---------------------------------------------------------------------------
-- 1. private.soft_delete_unreferenced_media：引用判定補上有效飲食記錄
--    與 20260906050606 的定義逐字相同，只多一個 `not exists`（child_food_records）。
-- ---------------------------------------------------------------------------
create or replace function private.soft_delete_unreferenced_media(
  p_grace interval default '24 hours',
  p_now timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.media m
     set deleted_at = p_now
   where m.deleted_at is null
     and m.type in ('photo', 'video')
     and m.created_at < p_now - p_grace
     and not exists (
       select 1 from public.diary_media dm
        where dm.family_id = m.family_id and dm.media_id = m.id
     )
     and not exists (
       select 1 from public.album_media am
        where am.family_id = m.family_id and am.media_id = m.id
     )
     -- LS-430：掛在有效（未軟刪）飲食記錄上的照片是被引用的，不是孤兒。
     and not exists (
       select 1 from public.child_food_records r
        where r.family_id = m.family_id and r.media_id = m.id and r.deleted_at is null
     );

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function private.soft_delete_unreferenced_media(interval, timestamptz) is
  '軟刪「media 列存在、deleted_at IS NULL、未被任何 diary_media／album_media／有效（未軟刪）'
  ' child_food_records 引用、且 created_at 超過寬限期（預設 24 小時）」的孤兒列（LS-213；'
  ' LS-430 補上飲食記錄引用）——與 docs/API.md §6「自動清除」③（Storage 有物件、media 列從未'
  ' insert 的孤兒）是兩支不同的查詢。處置是設 deleted_at＝走既有軟刪＋30 天 purge 流程，'
  ' 額度由 private.media_storage_sync() 既有 trigger 回落。p_now 預設 now()，測試注入固定值'
  ' 驗證寬限期邊界。security definer，只 service_role／pg_cron 可呼叫。';

-- ---------------------------------------------------------------------------
-- 2. 記錄刪除／換照片 → 釋放舊 media
-- ---------------------------------------------------------------------------
create or replace function private.release_food_record_media()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 併發：先鎖舊 media 列（理由見檔頭「併發」段）。media 已不存在（硬刪後的 FK set null）
  -- 則鎖 0 列、下面 UPDATE 也是 0 列。
  perform 1
    from public.media m
   where m.id = old.media_id and m.family_id = old.family_id
     for update;

  update public.media m
     set deleted_at = now()
   where m.id = old.media_id and m.family_id = old.family_id
     and m.deleted_at is null
     and not exists (
       select 1 from public.child_food_records r
        where r.family_id = m.family_id and r.media_id = m.id and r.deleted_at is null
     )
     and not exists (
       select 1 from public.diary_media dm
        where dm.family_id = m.family_id and dm.media_id = m.id
     )
     and not exists (
       select 1 from public.album_media am
        where am.family_id = m.family_id and am.media_id = m.id
     );

  return null;
end;
$$;

revoke execute on function private.release_food_record_media() from public, anon;

comment on function private.release_food_record_media() is
  'LS-430：飲食記錄不再引用舊 media（換照片／不用照片／記錄軟刪）時，若該 media 沒有任何其他'
  '引用（其他有效記錄、日記、相簿）即軟刪，走既有 30 天 purge。SECURITY DEFINER：owner 可刪'
  ' member 的記錄，member 上傳的 media 不在 owner 的 media_update 範圍內。見'
  ' 20261009065506_food_record_media_orphan.sql 檔頭。';

create trigger child_food_records_release_media
  after update of media_id, deleted_at on public.child_food_records
  for each row
  when (
    old.media_id is not null
    and old.deleted_at is null
    and (old.media_id is distinct from new.media_id or new.deleted_at is not null)
  )
  execute function private.release_food_record_media();
