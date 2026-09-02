-- LS-121 R2 併發場景 session 1：把相簿的孩子標記整組換成 {B, C}，故意壓住 3 秒
-- 不 commit。
--
-- 這 3 秒是 session 2 的窗口：`set_album_children` 開頭的
-- `select ... for update` 是這支 RPC 唯一的序列化手段（沒有像 `update_diary_entry`
-- 那樣還有一句對 `diaries` 本體的 UPDATE 順便取鎖——`set_album_children` 完全不
-- UPDATE `albums`）。若沒有真的鎖住相簿列，S2 會在這段時間內直接完成自己的
-- 「刪多補少」，跟 S1 的 commit 順序不確定，終態就可能混進 S1 還沒清乾淨、S2 也
-- 沒清到的殘留標記。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"e2000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_album_children(
  '4f000000-0000-4000-8000-000000000001',
  array['2e000000-0000-4000-8000-000000000002', '2e000000-0000-4000-8000-000000000003']::uuid[]);

select pg_sleep(3);

commit;

\echo 'S1：孩子標記已整組換成 {B, C} 並 commit'
