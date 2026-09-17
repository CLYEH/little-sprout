-- LS-320 hammer 場景驗證：`run.sh` 的 `race_case` 已經先檢查過 S1／S2 兩個連線
-- 皆以 rc=0 結束（80 回合裡任何一回合收到 40P01，該連線的 psql 腳本就會在
-- `\set ON_ERROR_STOP on` 下立刻非 0 中止，rc 檢查會抓到）。這裡再核對資料本身：
-- 兩張照片的孩子標記終態必須一致（不能一張是 {X}、另一張是 {Y}，那代表批次的
-- 兩筆 media 之間被不同回合的呼叫插花），且必須是 S1 的 {X} 或 S2 的 {Y} 其中一
-- 個完整集合（不能是 {X, Y} 混合，那代表同一張照片的覆蓋語意在併發下沒有互斥）。

\set ON_ERROR_STOP on

do $$
declare
  v_media1_children uuid[];
  v_media2_children uuid[];
  v_child_x uuid[] := array['63400000-0000-4000-8000-000000000001']::uuid[];
  v_child_y uuid[] := array['63400000-0000-4000-8000-000000000002']::uuid[];
begin
  select array_agg(child_id order by child_id) into v_media1_children
    from public.media_children where media_id = '63200000-0000-4000-8000-000000000001';
  select array_agg(child_id order by child_id) into v_media2_children
    from public.media_children where media_id = '63200000-0000-4000-8000-000000000002';

  if v_media1_children is distinct from v_media2_children then
    raise exception
      'FAIL hammer：兩張照片的終態不一致（照片1=%，照片2=%）——批次的兩筆 media 之間被插花，覆蓋語意在併發下沒有正確互斥',
      coalesce(v_media1_children, array[]::uuid[]), coalesce(v_media2_children, array[]::uuid[]);
  end if;

  if v_media1_children is distinct from v_child_x and v_media1_children is distinct from v_child_y then
    raise exception
      'FAIL hammer：終態應該是 S1 的 {X}（%）或 S2 的 {Y}（%）其中一個完整集合，實際是 %——同一張照片的覆蓋語意在併發下沒有正確互斥',
      v_child_x, v_child_y, coalesce(v_media1_children, array[]::uuid[]);
  end if;

  raise notice 'ok hammer：80 回合 ×2 連線（陣列順序相反）反覆用 set_media_children_batch 覆蓋同一組照片的孩子標記，全程無 40P01，終態一致且是其中一方的完整集合，沒有混合';
end;
$$;
