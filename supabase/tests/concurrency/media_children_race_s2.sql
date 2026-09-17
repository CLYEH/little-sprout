-- LS-317 merge-review R1 m2 併發場景 session 2：等 S1 先跑完整個批次呼叫並持鎖
-- 之後，才把兩張照片的孩子標記整組換成 {D}（陣列順序正常給：media1 在前、
-- media2 在後）——真正要驗的是終態（見 media_children_race_verify.sql）與兩邊
-- 皆以 rc=0 結束（沒有 40P01），不是這裡的等待秒數本身。
--
-- S1 已經完整持有兩張照片的鎖（sleep 期間），這裡不管 S2 自己的批次陣列給的是
-- 什麼順序，第一筆嘗試取鎖就會被 S1 卡住，等 S1 commit 才能繼續——這裡驗的是
-- 「批次交易在整個過程中持有所有涉及 media 的列鎖直到 commit」這個既有保證
-- （沿 `set_album_children` 的既有併發保證，migration 檔頭第 4 段），不是特別去
-- 重現 reviewer 手動抓到的微秒級 ABBA 交錯窗口（見 setup 檔頭「誠實記錄」段）。

\set ON_ERROR_STOP on

do $$
declare
  v_t0 timestamptz;
  v_elapsed double precision;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  -- 讓 session 1 的 set_media_children_batch（含取鎖）先跑完
  perform pg_sleep(1.2);

  v_t0 := clock_timestamp();
  perform public.set_media_children_batch(jsonb_build_array(
    jsonb_build_object('media_id', 'bd000000-0000-4000-8000-000000000001',
                        'child_ids', jsonb_build_array('bc000000-0000-4000-8000-000000000003')),
    jsonb_build_object('media_id', 'bd000000-0000-4000-8000-000000000002',
                        'child_ids', jsonb_build_array('bc000000-0000-4000-8000-000000000003'))
  ));
  v_elapsed := extract(epoch from clock_timestamp() - v_t0);

  commit;

  raise notice 'S2：等待 % 秒後完成，兩張照片的孩子標記整組換成 {D}', round(v_elapsed::numeric, 2);

  if v_elapsed < 0.5 then
    raise exception
      'FAIL 併發：S2 完全沒有等待（僅 % 秒）——這組場景的兩個連線應該對 S1 持有的 media 列鎖排隊，沒等到代表場景設計本身壞了（見 setup 檔頭「誠實記錄」段：這條斷言驗的是「兩個連線有交疊」，真正的判準在 verify.sql 的終態檢查）',
      round(v_elapsed::numeric, 2);
  end if;
end;
$$;
