-- LS-320 hammer 場景 session 2：80 回合，每回合都在同一個交易內把兩張照片的孩子
-- 標記整組換成 {Y}，陣列給的媒體順序刻意與 S1 相反，固定是 [media2, media1]。
-- 每回合各自 begin/commit（獨立小交易），不加任何人工 sleep——理由與 S1 同（見
-- `media_children_deadlock_hammer_setup.sql`／`_s1.sql` 檔頭）。

\set ON_ERROR_STOP on

begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
begin;
select set_config('request.jwt.claims',
  '{"sub":"63100000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', '63200000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('63400000-0000-4000-8000-000000000002'))
));
commit;
\echo 'S2：80 回合全部完成（每回合皆整組換成 {Y}），rc=0'
