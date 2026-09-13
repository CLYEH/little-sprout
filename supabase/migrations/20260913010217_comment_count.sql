-- LS-243（LS-22 後端切片；來源 LS-96 池項 f74e3a88，LS-216 ios-dev 自查）——
-- `get_family_timeline`／`list_comments` 都不回留言計數，互動列的留言鈕計數在使用者
-- 開過留言 sheet 之前恆顯示 0（`TimelineStore.commentCounts` 只在 `CommentsSheetView`
-- 讀到 `knownExactCount` 之後才被 `setCommentCount` 寫入，見 LS-237 對這兩支的既有
-- 文件註解）。本票補上兩支 RPC 各自的計數欄。
--
-- ---------------------------------------------------------------------------
-- 1. get_family_timeline：回傳列加 comment_count（正規化見下方 v_blocked_ids）
-- ---------------------------------------------------------------------------
--
-- 取捨（lateral count vs. 維護計數欄，票文要求交代）：選 correlated 子查詢（口語
-- 「lateral count」），不維護一個計數欄。理由：
--   (a) get_family_timeline 的外層 SELECT 已經在一個被 LIMIT 收斂到 ≤v_limit
--       （上限 100）列的衍生表 `p` 上運作——child_ids 的兩個 array_agg 子查詢
--       正是同一種「correlated 子查詢，只在已收斂的候選集合上逐列跑一次，走各自
--       PK／索引」寫法（見該函式既有說明），comment_count 沿用同一個時機與心智
--       模型，不引入第二套計數機制。
--   (b) 維護計數欄需要在 diaries／albums／media 三張表（comments 的合法 target）
--       上各補一欄＋在 comments 的 INSERT／軟刪／還原三個路徑上維護 trigger，
--       對一個「多型關聯、目標分散在三張表」的欄位來說，觸發器數量與失步風險
--       （trigger 漏補、補資料時忘記回填既有列）都比一句 correlated 子查詢高，
--       且這個 app 是私密家庭相簿、單一貼文的留言量級不會是「一頁要對幾萬則
--       留言計數」（那個量級只在 list_comments 的 total_count 底下才有意義的
--       壓力測試場景，見下方第 2 段）。
--   (c) 效能量測（`supabase/tests/50_rls_plan_no_percall_subquery.sql` 對
--       get_family_timeline 的既有 buffer 門檻回歸段落，200 筆 feed／limit=20）：
--       comment_count 子查詢命中 `comments_target_idx (family_id, target_type,
--       target_id, created_at) where deleted_at is null` 這個 partial index 的
--       前三欄（family_id／target_type／target_id 全部等值比對），對「這一頁
--       最多 v_limit 列，且這批效能 fixture 完全沒有任何留言」的資料集，量到的
--       是「索引探查到 0 筆就返回」的最低成本，不是隨全家庭 feed 或留言總量
--       增長的成本；真實情境下即使某一則貼文真的有幾十則留言，也只是這一列
--       多付幾個 buffers，不會是 N+1（沒有「每一列各發一次 RPC／查詢」，是同一次
--       函式呼叫內、對已經收斂到 ≤v_limit 列的候選集合逐列跑一次子查詢，跟
--       child_ids 的既有心智模型完全一致）。實測 EXPLAIN 原文與門檻調整見該測試
--       檔本次變更的段落。
--
-- 封鎖過濾（沿 list_comments 既有規則）：呼叫者已封鎖的人的留言不計入
-- comment_count。**不**沿用 child_ids 篩選旁邊、feed_items／feed_item_children
-- 外層掃描既有的「呼叫一次 private.blocked_pairs()、NOT EXISTS」寫法——那個寫法
-- 用在「决定驅動掃描的 WHERE 子句」時，一次 v_has_blocks=true 呼叫只需要付一次
-- （見既有 LS-149 設計裁量），但 comment_count 是**逐列**跑的 correlated 子查詢，
-- 若沿用同一招，v_limit 上限 100 時就是 100 次 private.blocked_pairs() 呼叫
-- （該函式雖是 language sql stable，但因為有 set search_path 子句而不會被規劃器
-- inline，一樣是 100 次真正的 Function Scan）。改成在函式最外層算一次
-- v_blocked_ids 陣列，逐列只做常數陣列的成員檢查（`= any(...)`），把「呼叫次數
-- 隨 v_limit 線性成長」降成「呼叫一次＋線性成長的是最便宜的記憶體比較」。
-- `not coalesce(x = any(arr), false)`：`arr` 為空陣列時 `x = any('{}')` 恆為
-- false（不論 x 是否為 NULL），效果等同「沒有封鎖」；`arr` 非空但 x（作者已被刪除
-- 帳號、`comments.author_id` 因 `on delete set null` 變成 NULL）時 `x = any(arr)`
-- 是 NULL，`coalesce(...,false)` 收斂成 false（不排除），跟原本 `NOT EXISTS`
-- 對 NULL author_id 一律回傳 true（不排除）的既有行為完全一致，不是新引入的
-- 邊界情況。
--
-- ---------------------------------------------------------------------------
-- 2. list_comments：回傳列加 total_count（同一 target 底下的留言總數，同上規則）
-- ---------------------------------------------------------------------------
--
-- 這裡不能沿用「correlated 子查詢，只在已收斂候選集合上跑」的心智模型——
-- total_count 定義上就是「這個 target 底下**全部**符合條件的留言數」，不是
-- 「這一頁 v_limit 列各自的計數」，沒有辦法只靠索引探查到 v_limit 筆就提早結束
-- （這正是 `supabase/tests/50_rls_plan_no_percall_subquery.sql` 對 list_comments
-- 既有壓力測試刻意灌到 5 萬則留言在同一個 target 上的理由：驗證分頁查詢的
-- buffers 只跟 limit 成正比、不跟該 target 的留言總量成正比）。加一句
-- `select count(*) into v_total_count from public.comments cm where ... `
-- 是唯一能拿到精確總數的辦法，成本必然是 O(該 target 底下符合條件的留言數)，
-- 不是 O(1)，也不是 O(v_limit)——這是精確計數的本質代價，不是本票寫壞。
-- 這**不是** N+1（不是「每一列各發一次查詢」，是**呼叫一次 list_comments，
-- 額外付一次聚合查詢**，跟分頁本身的查詢次數無關，翻十頁也只在每次呼叫各自
-- 付一次，不會疊加）。已同步更新 `supabase/tests/50_rls_plan_no_percall_
-- subquery.sql` 的 list_comments 段落 buffer 門檻，量測原文見該檔本次變更。
--
-- 用跟主查詢完全相同的過濾條件（`deleted_at is null`＋`v_blocked_ids` 封鎖
-- 過濾，見上方第 1 段對陣列寫法的完整說明）算 total_count，確保呼叫端拿到的
-- 總數與實際能翻到的頁數一致——不會出現「total_count 比翻完全部頁面撿到的
-- 留言數還多」這種不一致（因為兩者現在共用同一個 v_blocked_ids）。
--
-- 順手把 list_comments 兩條分支既有的 `not exists (select 1 from
-- private.blocked_pairs() bp where ...)` 換成同一個 v_blocked_ids 陣列檢查
-- （語意不變，見上方 coalesce 說明）——這兩條分支本來就只掃到 v_limit 列就
-- 提早結束（Index Scan Backward + LIMIT），單獨看即使沿用舊寫法也不是效能
-- 問題；換掉的理由純粹是**同一個函式裡不留兩套語意相同、只是因為新舊
-- 需求分開才長得不一樣的封鎖過濾寫法**——total_count 這句聚合查詢已經
-- 需要 v_blocked_ids，讓分頁查詢也共用同一份，讀者不必記得「這支函式裡有
-- 兩種寫法都在做同一件事」。
--
-- ---------------------------------------------------------------------------
-- 3. BREAKING：回傳形狀改變（`scripts/gates/migration-breaking-check.sh` B4：
--    CREATE OR REPLACE FUNCTION 對既有函式一律判 BREAKING，不分是否為 additive
--    變更）
-- ---------------------------------------------------------------------------
--
-- 兩支函式的參數簽章都沒變（`get_family_timeline(uuid, uuid, timestamptz, uuid,
-- integer)`／`list_comments(uuid, text, uuid, timestamptz, uuid, integer)`，
-- `60_default_privileges.sql`／`api_contract_check.py` 的白名單比對只看簽章，
-- 不需要跟著改）；回傳的 `returns table (...)` 各自多一欄（`comment_count`／
-- `total_count`），PostgREST 把 RPC 結果序列化成 JSON 物件陣列，Swift
-- `Decodable` 對多出來、呼叫端型別沒有宣告的 key 預設略過不報錯——現有兩支
-- 呼叫端（`TimelineFeedPointer`／`CommentRecord`）在這次改動落地前的舊 build
-- 不會因為伺服器多回一欄而解碼失敗。仍照 gate 指示標記 BREAKING（欄位新增本身
-- 對契約來說仍是「回傳形狀變了」，且 gate 的 B4 規則就是「既有函式一律 BREAKING，
-- 不分增量或替換」，不是這裡的裁量可以覆蓋的）。

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

create or replace function public.list_comments(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_id uuid,
  author_display_name text,
  author_avatar_url text,
  body text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
  -- LS-243：呼叫者在這個家庭封鎖過的所有人，一次性算成陣列——同
  -- public.get_family_timeline 的 v_blocked_ids 既有理由（見該函式宣告段）：
  -- 下面兩條分支原本的 `not exists (select 1 from private.blocked_pairs() bp
  -- where ...)` 換成陣列成員檢查，連同新增的 v_total_count 一次算完，不必為了
  -- total_count 另外多付一次 private.blocked_pairs() 呼叫。
  v_blocked_ids uuid[] := array(
    select bp.blocked_id from private.blocked_pairs() bp where bp.family_id = p_family_id
  );
  -- LS-243：總筆數（未刪除、排除封鎖者），跟目前這一頁用哪個游標無關，兩條分支共用
  -- 同一個值——分頁機制不變，這裡只是額外算一次「這個 target 底下總共有幾則」。
  -- 用跟主查詢完全相同的過濾條件（deleted_at is null／封鎖過濾），確保呼叫端拿到
  -- 的 total_count 與實際能翻到的頁數一致。這是一句單獨的聚合查詢（O(這個 target
  -- 底下的留言數)），不是逐列查詢——見 migration 檔頭效能說明的取捨記錄。
  v_total_count bigint;
begin
  if v_uid is null then
    raise exception '未登入，無法讀取留言' using errcode = '42501';
  end if;

  if not private.caller_is_active() then
    raise exception '這個帳號已被暫停使用，請聯絡我們' using errcode = 'LS052';
  end if;

  if not private.family_is_active(p_family_id) then
    raise exception '這個家庭已被暫停使用，請聯絡我們' using errcode = 'LS053';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能讀取留言' using errcode = '42501';
  end if;

  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_created_at／p_cursor_id）'
      using errcode = 'LS022';
  end if;

  select count(*) into v_total_count
    from public.comments cm
   where cm.family_id = p_family_id
     and cm.target_type = v_target_type
     and cm.target_id = p_target_id
     and cm.deleted_at is null
     and not coalesce(cm.author_id = any(v_blocked_ids), false);

  if p_cursor_created_at is null then
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at, v_total_count
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and not coalesce(cm.author_id = any(v_blocked_ids), false)
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  else
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at, v_total_count
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and (cm.created_at, cm.id) < (p_cursor_created_at, p_cursor_id)
             and not coalesce(cm.author_id = any(v_blocked_ids), false)
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  end if;
end;
$$;

revoke execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  to authenticated;
