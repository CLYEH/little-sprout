-- LS-175（LS-22 後端切片）——`media` 新增彙總通知事件：批次上傳合併成一則
-- 「<actor> 新增了 N 張照片」。補上 merge-reviewer LS-172 R1 i1 點名的缺口：
-- `notification_events` 目前只由 comments／reactions／diaries／albums 四張表
-- 的 AFTER INSERT trigger 餵入（LS-58），`media` 表沒有——`docs/PLAN.md` 風險章
-- 「批次上傳 50 張照片要合併成一則」在此之前根本沒有事件可產生。
--
-- ---------------------------------------------------------------------------
-- 設計裁量：target 只能是「整個家庭」，不是「該批照片所屬的相簿／日記」
--
-- 這不是本票偷懶簡化，是結構性事實（完整推導見上一支 migration
-- 20260904170849_media_notification_target_family.sql 檔頭）：`media` 表沒有
-- album_id／diary_id 欄位，一張照片是否掛進相簿／日記，是透過 album_media／
-- diary_media 這兩張連結表**另一次、之後才發生**的寫入——`album_media`／
-- `diary_media` 的複合外鍵（`references public.media (family_id, id)`）要求
-- media 列必須先存在，所以 `media` 表自己的 AFTER INSERT trigger 在觸發當下，
-- 這批照片究竟會不會、會掛進哪個相簿／日記，這個資訊在資料庫裡根本還不存在
-- （不是「查詢寫錯」，是「時間點上還沒有東西可查」）。對 album_media／
-- diary_media 做 JOIN 只會查到 0 列，是一段看起來有作用、實際上恆假的死邏輯，
-- 這裡不寫。
--
-- 副作用（刻意接受）：這代表 kind='album'（`private.notify_album_created`）與
-- 本票的 kind='media' 是兩個完全獨立、不會互相合併的事件——「建立一本新相簿」
-- 與「上傳照片」（不論最終有沒有掛進相簿）各自各發各的通知。如果同一個使用者
-- 動作實際上是「建立相簿並同時塞照片進去」，使用者會收到兩則通知，不是一則。
-- 這不在本票範圍內解決（票文明定：「純上傳無歸屬用 target_type='family'」，
-- 依上述結構性理由這其實是唯一會發生的分支，不是邊界情況）；`docs/PLAN.md`
-- 風險章與 `docs/API.md` §10 皆已同步這個取捨。
--
-- ---------------------------------------------------------------------------
-- 彙總鍵：family_id + kind('media') + target_type('family') + target_id
-- (=family_id) ——同一個家庭在 5 分鐘滾動視窗內的多次上傳（不論是一次多列
-- INSERT，還是像實際 client 那樣逐張各自一次單列 INSERT，見
-- `LittleSprout/Services/Diary/MediaUploadService.swift`）都會合併進同一筆，
-- `event_count` 累加**張數**（不是批次數／INSERT 次數）——沿用既有
-- `private.record_notification_event()` 的滾動視窗＋advisory lock，語意與
-- comments／reactions／diaries／albums 四種既有來源完全一致，不需要任何新機制。
--
-- 只在 `deleted_at is null` 時觸發（票文明定）：軟刪／還原不通知。AFTER INSERT
-- trigger 本來就不會被 UPDATE（軟刪／還原）觸發，這裡的 WHERE 子句防的是另一種
-- 邊界——`media` 對 authenticated 的 INSERT grant 是整表授權、不是逐欄列舉（見
-- `init_schema.sql`：「grant select, insert, delete on public.media」，跟同表
-- UPDATE 的逐欄列舉不同），理論上一句 INSERT 可以夾帶 `deleted_at` 一起寫入
-- （目前沒有任何 client 這樣做，`MediaUploadService.insertMediaRow` 也不會傳這
-- 一欄），防禦性地把這種列排除在分組之外，不讓「插入當下就已軟刪的列」也算一次
-- 新增通知。
--
-- 沿用本 schema 既有的 statement-level trigger 慣例（AFTER INSERT、
-- REFERENCING NEW TABLE AS new_rows、FOR EACH STATEMENT、先 GROUP BY 再呼叫
-- record_notification_event，同 20260825020000 第 3 段「批次寫入改成先分組再
-- 合併」的既有理由：批次寫入只觸發一次函式呼叫，不是每列各自觸發一次）。
-- 目前實際的寫入路徑（`MediaUploadService`）恆為單列 INSERT，這裡的 GROUP BY
-- 對單列輸入是恆等變換，跟 notify_diary_created／notify_album_created 同一個
-- 「防禦性一致，不是為了今天的效能」的理由——若日後真的出現一次多列的批次
-- INSERT（例如伺服器端匯入工具），trigger 已經是正確形狀，不必回頭改。
create or replace function private.notify_media_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select family_id, count(*)::integer as n,
           (array_agg(uploaded_by order by created_at desc))[1] as actor_id
      from new_rows
     where deleted_at is null
     group by family_id
  loop
    perform private.record_notification_event(
      r.family_id, 'media', 'family', r.family_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger media_notify_insert after insert on public.media
  referencing new table as new_rows
  for each statement execute function private.notify_media_created();

comment on trigger media_notify_insert on public.media is
  'LS-175：批次上傳彙總進 notification_events（kind=''media''，target_type=
  ''family''，target_id=family_id）——只在 deleted_at is null 時計入，5 分鐘
  滾動視窗合併規則沿用 private.record_notification_event()，同
  comments/reactions/diaries/albums 四張既有來源表的既有機制。target 為什麼是
  整個家庭、不是所屬相簿／日記，見本檔與上一支 migration 的檔頭完整說明。';
