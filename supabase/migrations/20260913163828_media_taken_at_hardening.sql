-- LS-262（LS-249 後端先行；00:5x 訂正版，見票 comment）——補強既有 `media.taken_at`
-- （EXIF 原始拍攝時間，`20260822120000_init_schema.sql:129`）：邊界 CHECK、
-- `get_family_timeline` 回傳原始值、索引需求評估、SQL 測試。**不新增欄位**——原票文
-- 「新增 `captured_at`」是 orchestrator 開票時未查 schema 的錯誤，`taken_at` 已是
-- 同語意欄位且已在生產路徑上（client INSERT／UPDATE 回填，`feed_items.occurred_at`
-- 已是 `coalesce(taken_at, created_at)`，見 `20260822120100_triggers.sql:104,154`），
-- 詳細發現記錄見票 comment，這裡不重複。
--
-- ---------------------------------------------------------------------------
-- 1. `media.taken_at` 邊界 CHECK（票面：早於 1970 或晚於「現在＋1 天」拒絕）
-- ---------------------------------------------------------------------------
--
-- `not valid` 兩步（先加不驗證既有列，再單獨 `validate constraint`）：`media` 表
-- 目前已有既有列（LS-249 之前所有既有上傳與既有 `taken_at` 回填），若既有資料剛好
-- 卡在新邊界外（理論上不該發生，但沒有先驗證過就不能假設），直接
-- `ADD CONSTRAINT ... CHECK (...)`（不帶 `NOT VALID`）在既有列違反時整句 migration
-- 失敗、擋住其餘變更；`NOT VALID` 讓新 CHECK 只對之後的 INSERT/UPDATE 生效，既有列
-- 由下一句 `VALIDATE CONSTRAINT` 單獨掃描驗證，掃描失敗時只有這一句紅、其餘變更
-- （下面的 `get_family_timeline` 改動）不受影響，且能明確定位是哪一步壞（同
-- `information_schema` 官方建議的既有慣例寫法）。
--
-- 邊界值選 `now() + interval '1 day'`（不是 `now()`）：EXIF `DateTimeOriginal`／
-- 裝置時鐘與伺服器時鐘之間可能有時區/時鐘飄移（例如使用者手機時間比伺服器快幾小時、
-- 或跨日界時上傳），留一天緩衝是常見容忍量級，避免合法的「剛拍完就上傳」被邊界值
-- 誤擋；票面明訂「未來值（>now()+1 天）拒絕」，這裡照字面實作。CHECK 使用 `now()`
-- （STABLE，非 IMMUTABLE）——PostgreSQL 對一般資料表的 CHECK 約束沒有强制運算式必須
-- IMMUTABLE 的限制（只有函式索引／GENERATED 欄位才要求），`now()` 在 CHECK 裡的既有
-- 語意是「每次 INSERT/UPDATE 當下重新求值」，正是這裡要的行為（拒絕「當下」看起來是
-- 未來的值，不是要求這個約束對已寫入的列之後仍逐秒保持為真）；`VALIDATE CONSTRAINT`
-- 掃描既有列時同樣用驗證當下的 `now()`，只要既有 `taken_at` 都不晚於驗證當下＋1天
-- （正常情況下必然成立，過去回填的值不會是未來），就會通過。
alter table public.media
  add constraint media_taken_at_range_check
  check (
    taken_at is null
    or (taken_at >= '1970-01-01'::timestamptz and taken_at <= now() + interval '1 day')
  )
  not valid;

alter table public.media
  validate constraint media_taken_at_range_check;

-- ---------------------------------------------------------------------------
-- 2. 索引需求評估（票面：「若時間軸／相簿未來要依 occurred_at 排序，feed_items
--    已有自己的索引則本票不加，handoff 說明結論，不憑感覺加索引」）
-- ---------------------------------------------------------------------------
--
-- 結論：**本票不新增索引**。
--   - 時間軸排序：`get_family_timeline` 排序鍵是 `feed_items.occurred_at`
--     （`coalesce(taken_at, created_at)`，寫入時已算好存進 `feed_items`），既有
--     `feed_items_family_occurred_idx (family_id, occurred_at desc, ref_id desc)`／
--     `feed_items_family_child_occurred_idx` 已覆蓋這個排序鍵，本票只是多回傳
--     `taken_at` 原始值供呼叫端顯示／判斷「是否有 EXIF」，**不改變排序鍵本身**
--     （票面「排序規則不變」），既有索引不受影響、不需要新增。
--   - 相簿列表：目前沒有一支「依拍攝日排序」的相簿 media 查詢——`album_summaries`
--     view 的 `latest_*` 三欄與相簿內容目前皆依 `media.created_at` 排序
--     （`20260905074037_album_summaries_view.sql`），本票依票面「不改語意」不動它
--     （見下方第 3 段）；client 若要直接查詢單一相簿內 media 並依 `taken_at` 排序，
--     這是透過 PostgREST 對 `media`／`album_media` 的一般 `.select()`（RLS 已允許
--     整欄 SELECT，見 `docs/API.md` §3 media 段既有文件），現有 `media` 表本身沒有
--     `album_id` 欄位（相簿關聯是 `album_media` 多對多連結表），不存在票面原稿誤寫的
--     `(album_id, captured_at)` 這種索引形狀；若日後 LS-251 設計裁決要支援「相簿內
--     依拍攝日排序」，會是另一次查詢型態＋索引評估，本票不預先加一個目前沒有查詢
--     會用到的索引（YAGNI，也是 CLAUDE.md「不做投機性彈性」的既有原則）。
--   - `media_taken_at_range_check` 是 CHECK 約束，不是索引需求。
--
-- ---------------------------------------------------------------------------
-- 3. `album_summaries` view 是否需要同步 `taken_at`——評估結論（票面：「若有
--    cover／最新時間欄位以 created_at 計算，評估是否需同步，結論寫 handoff，不改
--    語意」）
-- ---------------------------------------------------------------------------
--
-- 結論：**不改**。`album_summaries` 的 `latest_media_id`／`latest_thumb_path`／
-- `latest_storage_path` 三欄定義是「該相簿底下依 `m.created_at desc, m.id desc`
-- 排序的第一筆」（見 view 定義的 LATERAL 子查詢，`20260905074037_album_summaries_
-- view.sql`），語意是「最後被加進這本相簿的照片」（用於相簿封面／縮圖），不是
-- 「拍攝時間最新的照片」——這兩個語意本來就不同，票面本身也明講「不改語意」，因此
-- 不需要也不應該把排序鍵換成 `taken_at`；`album_summaries` 沒有回傳任何時間欄位
-- 供呼叫端排序使用（`a.*` 展開的是 `albums` 表欄位，`albums` 沒有 `taken_at`），
-- 這裡也沒有「該不該多回傳 taken_at」的欄位缺口需要補——若之後 LS-251 設計需要
-- 相簿列表依拍攝日排序，會是對 `album_summaries` 或另一支查詢的新需求，不在本票
-- 範圍內。

-- ---------------------------------------------------------------------------
-- 4. `get_family_timeline` 回傳列加 `taken_at`（純加欄；純資料庫函式，不含
--    schema 名稱以外的商業邏輯，這裡不重複整段既有函式的既有機制，只在既有
--    `return query select ...` 的欄位清單插入這一欄——完整函式本體照舊，只有
--    `returns table` 宣告與 8 個 `return query` 分支的 SELECT 清單各多一欄）
-- ---------------------------------------------------------------------------
--
-- **DESTRUCTIVE＋BREAKING**（沿 `20260913010217_comment_count.sql` 第 3 段
-- 記錄過的同一個 Postgres 限制與同一套解法）：`RETURNS TABLE` 的欄位型別是 OUT
-- 參數複合型別，`CREATE OR REPLACE FUNCTION` 不允許改變既有函式的 OUT 參數型別
-- （`ERROR: cannot change return type of existing function`，`SQLSTATE 42P13`），
-- 只能先 `DROP FUNCTION` 再 `CREATE OR REPLACE` 同簽章重建。`migration-breaking-
-- check.sh` 的 D1（DROP 任何物件）與 B4（CREATE OR REPLACE 既有函式）因此同時命中
-- ——DESTRUCTIVE＋BREAKING 兩級都要，PR body 需要 owner 本人的 `DESTRUCTIVE-
-- APPROVED` 核可標記留言＋`BREAKING:` 摘要段。參數簽章沒變
-- （`get_family_timeline(uuid, uuid, timestamptz, uuid, integer)`），
-- `60_default_privileges.sql`／`api_contract_check.py` 的白名單比對只看簽章，不需要
-- 跟著改；`DROP FUNCTION` 到 `CREATE OR REPLACE` 之間沒有中間狀態以外的風險（同一個
-- migration 檔內連續兩句 DDL，套用時間毫秒級）。多回傳的 `taken_at` 欄同
-- `comment_count`／`child_ids` 的既有先例：PostgREST 序列化成 JSON 物件，Swift
-- `Decodable` 對型別沒宣告的多餘 key 預設略過不報錯，現有呼叫端
-- （`TimelineFeedPointer`）不會因為伺服器多回一欄而解碼失敗。
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
  taken_at timestamptz,
  child_ids uuid[],
  comment_count bigint
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  -- LS-243：呼叫者在這個家庭封鎖過的所有人，一次性算成陣列（不是逐列呼叫
  -- private.blocked_pairs()）——comment_count 子查詢在下面對每一列（最多 v_limit
  -- 列）都要判斷一次作者是否被封鎖，若沿用 child_ids 那種「per-row 呼叫 SQL
  -- 函式」的寫法，v_limit 上限 100 時就是 100 次 private.blocked_pairs() 呼叫；
  -- 改成陣列後，每一列只是一個常數陣列的 in-memory 成員檢查，不再有額外函式呼叫，
  -- 見 supabase/tests/50_rls_plan_no_percall_subquery.sql 對 comment_count 的
  -- 效能回歸段落。空陣列（無封鎖）時 `= any('{}')` 恆為 false，語意與「沒有封鎖」
  -- 完全一致，不需要另外判斷是否為空。
  v_blocked_ids uuid[] := array(
    select bp.blocked_id from private.blocked_pairs() bp where bp.family_id = p_family_id
  );
  -- 一次性判斷（不是逐列）：呼叫者在這個家庭封鎖過任何人嗎？絕大多數情況是 false，
  -- 走完全未加過濾條件的原始查詢，效能不受影響（見上方說明）。沿用 v_blocked_ids
  -- 算出來的陣列，不再另外呼叫一次 private.blocked_pairs()。
  v_has_blocks boolean := coalesce(array_length(v_blocked_ids, 1), 0) > 0;
begin
  if (p_cursor_occurred_at is null) <> (p_cursor_ref_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_occurred_at／p_cursor_ref_id）'
      using errcode = 'LS022';
  end if;

  if p_child_id is null then
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select f.kind, f.ref_id, f.occurred_at
                from public.feed_items f
               where f.family_id = p_family_id
                 and (f.occurred_at, f.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = f.family_id
                      and bp.blocked_id = private.feed_item_actor_id(f.kind, f.ref_id)
                 )
               order by f.occurred_at desc, f.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
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
    end if;
  else
    if p_cursor_occurred_at is null then
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      end if;
    else
      if v_has_blocks then
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
            from (
              select fc.kind, fc.ref_id, fc.occurred_at
                from public.feed_item_children fc
               where fc.family_id = p_family_id
                 and fc.child_id = p_child_id
                 and (fc.occurred_at, fc.ref_id) < (p_cursor_occurred_at, p_cursor_ref_id)
                 and not exists (
                   select 1 from private.blocked_pairs() bp
                    where bp.family_id = fc.family_id
                      and bp.blocked_id = private.feed_item_actor_id(fc.kind, fc.ref_id)
                 )
               order by fc.occurred_at desc, fc.ref_id desc
               limit v_limit
            ) p
           order by p.occurred_at desc, p.ref_id desc;
      else
        return query
          select p.kind, p.ref_id, p.occurred_at,
                 -- LS-262：原始 taken_at（僅 kind='media' 有意義，見函式頭段落 4 的
                 -- 說明；其餘 kind 的 CASE 無 ELSE 分支，SQL 語意即為 NULL）。
                 (case p.kind
                    when 'media' then (select m.taken_at from public.media m where m.id = p.ref_id)
                  end) as taken_at,
                 coalesce(
                   case p.kind
                     when 'diary' then (select array_agg(dc.child_id order by dc.child_id)
                                          from public.diary_children dc where dc.diary_id = p.ref_id)
                     when 'album' then (select array_agg(ac.child_id order by ac.child_id)
                                          from public.album_children ac where ac.album_id = p.ref_id)
                   end,
                   '{}'::uuid[]
                 ) as child_ids,
                 -- LS-243：comment_count——correlated 子查詢對 p_family_id/p.kind/p.ref_id
                 -- 三欄命中 comments_target_idx（family_id, target_type, target_id,
                 -- created_at）where deleted_at is null 這個 partial index 的前三欄，
                 -- 只在已經被 LIMIT 收斂到 ≤v_limit 列的 p 上逐列跑一次，跟 child_ids
                 -- 的 array_agg 子查詢是同一種「correlated 子查詢，走各自索引」時機
                 -- （見 API.md 對 get_family_timeline 效能說明的既有寫法），不是對整個
                 -- feed 的 N+1。封鎖過濾比照 list_comments 規則，但用上面 v_blocked_ids
                 -- 陣列而不是逐列呼叫 private.blocked_pairs()（理由見宣告段）。
                 (select count(*)::bigint
                    from public.comments cm
                   where cm.family_id = p_family_id
                     and cm.target_type = (p.kind::text)::public.content_target_type
                     and cm.target_id = p.ref_id
                     and cm.deleted_at is null
                     and not coalesce(cm.author_id = any(v_blocked_ids), false)
                 ) as comment_count
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
  end if;
end;
$$;

revoke execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
  to authenticated;
