-- 併發場景（方向 C：作者搬家先動）的 session 1：作者把自己建立的相簿直接 UPDATE
-- 搬到自己也是 owner 的另一個家庭（f8），故意壓住 3 秒不 commit。
--
-- 這組是 merge-reviewer PR #70 review N1（第 2 輪）指出的真正缺口：原本方向 A／B
-- 只驗「作者改 title」與 owner 的軟刪序列化，但 title 不是 set_album_deleted
-- 讀來做授權判斷的欄位，測不出 `for update` 的必要性；`family_id` 才是——這裡改
-- `family_id`，才踩得到那個判斷。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

update public.albums set family_id = 'f8000000-0000-4000-8000-000000000001'
 where id = '49000000-0000-4000-8000-000000000001';

select pg_sleep(3);

commit;

\echo 'S1：作者的搬家 UPDATE 已 commit（相簿現在屬於 f8）'
