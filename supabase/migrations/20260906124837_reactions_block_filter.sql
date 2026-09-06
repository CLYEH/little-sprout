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
-- `get_reaction_counts` 是 `language sql`／非 SECURITY DEFINER，符合 Postgres inline
-- 條件，EXPLAIN 對呼叫本身可以直接看到內層 plan（不像 SECURITY DEFINER 或 plpgsql
-- 函式那樣是不透明的 Function Scan 黑盒）。
--
-- `reacted_by_me` 刻意不受影響：述詞只排除「呼叫者已封鎖的人的反應」，呼叫者自己的
-- `user_id = auth.uid()` 一定不會被自己的封鎖名單排除（`blocked_users_not_self` 約束
-- 也禁止自我封鎖），`bool_or` 聚合前 `r.user_id` 已經被過濾掉的列本來就不會參與比對，
-- 但呼叫者自己的列從來不會被過濾掉。
--
-- `toggle_reaction` 寫入路徑不動（票文範圍：只補讀取兩處）。

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
