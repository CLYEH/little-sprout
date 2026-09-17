-- LS-320 hammer 場景 session 1：80 回合，每回合都在同一個交易內把兩張照片的孩子
-- 標記整組換成 {X}，陣列給的媒體順序固定是 [media1, media2]。每回合各自
-- begin/commit（獨立小交易），刻意不加任何人工 sleep——見
-- `media_children_deadlock_hammer_setup.sql` 檔頭：兩連線緊接著跑、速度相近，
-- 80 次裡幾乎必然會與 S2（陣列順序相反）交錯出鎖序 deadlock 的窗口。
--
-- 偏離票文「set local deadlock_timeout = '20ms'」：`deadlock_timeout` 的 GUC
-- context 是 `superuser`（實測 `select context from pg_settings where
-- name='deadlock_timeout'` = superuser），這裡跑的 role `authenticated` 不是
-- 超級使用者，`set local deadlock_timeout` 會直接 `ERROR: permission denied to
-- set parameter`。改成全域（`ALTER DATABASE ... SET`／`GRANT SET ON PARAMETER`）
-- 才繞得過去，但票文「不做」段明訂不改 `deadlock_timeout` 全域設定——兩者衝突，
-- 依票文為準，這裡維持 Postgres 預設 1 秒偵測延遲。不影響正確性：ON_ERROR_STOP
-- 讓腳本在第一個 40P01 就立刻中止，最多只有一回合需要等滿 1 秒偵測，80 回合裡
-- 只要撞上任何一次 ABBA 循環等待就會被抓到。

\set ON_ERROR_STOP on

begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000001'))
));
commit;
\echo 'S1：80 回合全部完成（每回合皆整組換成 {X}），rc=0'
