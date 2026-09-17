-- LS-317 merge-review R1 m2 併發場景驗證：終態必須是兩張照片都整組換成 S2
-- （後 commit 的一方）的完整集合 {D}，不能是 {C, D} 這種混合結果，也不能是
-- S1 的 {C}——run.sh 的 race_case 已經先檢查過 S1／S2 皆以 rc=0 結束（沒有任何
-- 一個收到 40P01），這裡再核對資料本身沒有跨兩筆 media 混合、也沒有跨兩個
-- 呼叫端的結果混合。

\set ON_ERROR_STOP on

do $$
declare
  v_media1_children uuid[];
  v_media2_children uuid[];
  v_expected uuid[] := array['bc000000-0000-4000-8000-000000000003']::uuid[];
begin
  select array_agg(child_id order by child_id) into v_media1_children
    from public.media_children where media_id = 'bd000000-0000-4000-8000-000000000001';
  select array_agg(child_id order by child_id) into v_media2_children
    from public.media_children where media_id = 'bd000000-0000-4000-8000-000000000002';

  if v_media1_children is distinct from v_expected then
    raise exception
      'FAIL 併發：照片1 的終態應該是 S2 的完整集合 {D}（%），實際是 %——批次覆蓋語意在併發下沒有正確互斥',
      v_expected, coalesce(v_media1_children, array[]::uuid[]);
  end if;

  if v_media2_children is distinct from v_expected then
    raise exception
      'FAIL 併發：照片2 的終態應該是 S2 的完整集合 {D}（%），實際是 %——批次覆蓋語意在併發下沒有正確互斥',
      v_expected, coalesce(v_media2_children, array[]::uuid[]);
  end if;

  raise notice 'ok 併發：兩個順序相反的重疊批次（set_media_children_batch）同時覆蓋同一組照片的孩子標記，兩邊皆無 40P01，終態正確是後 commit 那一方的完整集合，兩張照片一致，沒有混合';
end;
$$;
