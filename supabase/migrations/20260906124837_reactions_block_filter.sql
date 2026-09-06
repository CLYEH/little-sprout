-- LS-225（LS-23 後端切片）——LS-149 的封鎖過濾漏了 reactions：`get_reaction_counts()`
-- 與 `reactions_select` policy 都沒有 `blocked_pairs` 述詞，A 封鎖 B 後 B 的愛心仍計入
-- A 看到的 reaction_count，按讚名單（LS-216 直接 select reactions join profiles）也仍
-- 列出 B。LS-216 merge-review R1 i1（記入 LS-96 待辦池，升格獨立票）。
--
-- 沿用 LS-149（20260903091317_report_block_rpc.sql）的既有寫法，不自創：
--   - `private.blocked_pairs()`：STABLE SECURITY DEFINER，回傳呼叫者（auth.uid()）
--     在各家庭封鎖的名單（family_id, blocked_id），albums_select／comments_select／
--     get_family_timeline／list_comments 已共用同一份判斷。
--   - NOT EXISTS 子查詢明確用表名限定欄位（`reactions.family_id`／`reactions.user_id`，
--     不用裸欄名）——裸欄名在子查詢範圍內會先比對到 `bp.family_id`，造成恆真的
--     `bp.family_id = bp.family_id`（LS-149 migration 檔頭已記錄這個陷阱）。
--   - RLS policy 用 `alter policy ... using (...)`（同 albums_select／comments_select
--     的既有寫法），不是 drop/create——單一 DDL 語句原地換條件，沒有「policy 不存在」
--     的中間視窗，也不必重複宣告 for/to 子句。
--
-- 效能：`reactions_target_idx (family_id, target_type, target_id)` 先把候選集合縮到
-- p_target_ids／單一 target_id 範圍，population 小；`blocked_pairs()` 內部靠
-- `blocked_users_blocker_idx (blocker_id)` 一次查出呼叫者的封鎖名單，不是 per-row
-- 查詢（跟 get_family_timeline 當初 per-row 函式呼叫踩雷、事後改用 v_has_blocks 分支
-- 的情況不同——這裡從一開始就是「先查一次候選封鎖名單，再對已經被索引縮小的候選集合
-- 做 anti join」的形狀，見 supabase/tests/109_reactions_block_filter.sql 的 EXPLAIN 段）。
-- `get_reaction_counts` 帶 `set search_path = ''`（本專案每支函式的既有慣例）——
-- 有 SET 子句的函式一律被 Postgres 排除在 inline 條件之外（不分 invoker／definer、
-- 不分 sql／plpgsql），所以 EXPLAIN 對呼叫本身只會看到一個不透明的
-- `Function Scan on get_reaction_counts` 節點，看不進內層 plan——跟下面第 34-44 行
-- 的既有事實一致。`supabase/tests/111_reactions_block_filter.sql` 的效能證據段因此
-- 改成對真正的 RPC 呼叫量 buffers（merge-review R1 M1 裁定，不手抄函式本體副本）。
--
-- `reacted_by_me` 刻意不受影響：述詞只排除「呼叫者已封鎖的人的反應」，呼叫者自己的
-- `user_id = auth.uid()` 一定不會被自己的封鎖名單排除（`blocked_users_not_self` 約束
-- 也禁止自我封鎖），`bool_or` 聚合前 `r.user_id` 已經被過濾掉的列本來就不會參與比對，
-- 但呼叫者自己的列從來不會被過濾掉。
--
-- `toggle_reaction` 寫入路徑不動（票文範圍：只補讀取兩處）。
--
-- 實測發現（mutation 驗證時發現，記在這裡避免下一個改這支函式的人誤解）：
-- `get_reaction_counts` 是 security invoker（LS-58 既有裁量），`FROM public.reactions r`
-- 這一行本身就會受呼叫者身分的 `reactions_select` RLS 約束——也就是說，只要
-- `reactions_select` policy 有這個 NOT EXISTS，即使把 RPC 本體這裡的 NOT EXISTS
-- 拿掉，計數仍然會被正確過濾（RLS 已經先把看不到的列擋在 `r` 之外）。RPC 本體這裡
-- 的述詞因此對「security invoker」這支函式來說是防禦性重複（policy 才是真正生效的
-- 那一層），不是漏了就會壞掉的必要條件。保留它的理由：(a) 跟 albums_select／
-- comments_select／list_comments／get_family_timeline 的既有模式一致，讀者不需要
-- 記得「這支剛好是 invoker，邏輯在 RLS」這個例外；(b) 自我文件化——函式簽章旁邊就能
-- 看到完整的過濾條件，不必跳去看 policy 定義；(c) 如果日後 `reactions_select` 被
-- 改壞（例如又是一次 policy 重建漏了述詞），這裡仍是第二道防線。

create or replace function public.get_reaction_counts(
  p_family_id uuid,
  p_target_type text,
  p_target_ids uuid[]
)
returns table (
  target_id uuid,
  reaction_count bigint,
  reacted_by_me boolean
)
language sql
stable
set search_path = ''
as $$
  select r.target_id,
         count(*)::bigint as reaction_count,
         bool_or(r.user_id = (select auth.uid())) as reacted_by_me
    from public.reactions r
   where r.family_id = p_family_id
     and r.target_type = p_target_type::public.content_target_type
     and r.target_id = any (p_target_ids)
     and not exists (
       select 1 from private.blocked_pairs() bp
        where bp.family_id = r.family_id
          and bp.blocked_id = r.user_id
     )
   group by r.target_id;
$$;

alter policy reactions_select on public.reactions using (
  family_id in (select private.family_ids())
  and not exists (
    select 1 from private.blocked_pairs() bp
     where bp.family_id = reactions.family_id
       and bp.blocked_id = reactions.user_id
  )
);
