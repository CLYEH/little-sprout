-- LS-121 併發場景 session 1：把日記的孩子標記整組換成 {B, C}，故意壓住 3 秒不 commit。
--
-- 這 3 秒是 session 2 的窗口：update_diary_entry 若對同一篇日記的兩次覆蓋沒有
-- 序列化（施力點是 RPC 本體那句 `update diaries set body = ...`，見
-- diary_children_race_s2.sql 檔頭 R2 訂正），S2 會在這段時間內直接完成自己的
-- 「刪多補少」，跟 S1 的 commit 順序不確定，終態就可能混進 S1 還沒清乾淨、S2 也
-- 沒清到的殘留標記。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.update_diary_entry(
  '58000000-0000-4000-8000-000000000001', 'S1 改的內容', current_date,
  array['28000000-0000-4000-8000-000000000002', '28000000-0000-4000-8000-000000000003']::uuid[]);

select pg_sleep(3);

commit;

\echo 'S1：孩子標記已整組換成 {B, C} 並 commit'
