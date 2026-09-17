-- LS-317 merge-review R1 m2 併發場景 session 1：把兩張照片的孩子標記整組換成
-- {C}——呼叫端刻意把陣列順序倒過來給（media2 在前、media1 在後），故意壓住 3 秒
-- 不 commit。
--
-- 這 3 秒是 session 2 的窗口：`set_media_children_batch` 內部依 media_id 排序取
-- 鎖（R2 修法），所以不論這裡的陣列給的是什麼順序，實際鎖序都是 media1 先、
-- media2 後——這裡刻意倒著給陣列剛好驗到「陣列順序不影響結果」這件事，不是為了
-- 製造循環等待（批次呼叫本身在沒有外部鎖競爭時一定會直接完成，兩筆都成功後才
-- sleep，此時已經同時持有兩張照片的鎖）。

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select public.set_media_children_batch(jsonb_build_array(
  jsonb_build_object('media_id', 'bd000000-0000-4000-8000-000000000002',
                      'child_ids', jsonb_build_array('bc000000-0000-4000-8000-000000000002')),
  jsonb_build_object('media_id', 'bd000000-0000-4000-8000-000000000001',
                      'child_ids', jsonb_build_array('bc000000-0000-4000-8000-000000000002'))
));

select pg_sleep(3);

commit;

\echo 'S1：兩張照片的孩子標記已整組換成 {C} 並 commit'
