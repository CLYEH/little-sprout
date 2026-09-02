-- LS-121 R2 併發場景驗證：終態必須是 S2（後 commit 的一方）的完整集合 {D}，
-- 不能是 {B, C, D} 這種混合結果，也不能是 S1 的 {B, C}。

\set ON_ERROR_STOP on

do $$
declare
  v_children uuid[];
  v_expected uuid[] := array['2e000000-0000-4000-8000-000000000004']::uuid[];
begin
  select array_agg(child_id order by child_id) into v_children
    from public.album_children where album_id = '4f000000-0000-4000-8000-000000000001';

  if v_children is distinct from v_expected then
    raise exception
      'FAIL 併發：終態應該是 S2 的完整集合 {D}（%），實際是 %——覆蓋語意在併發下沒有正確互斥',
      v_expected, coalesce(v_children, array[]::uuid[]);
  end if;

  raise notice 'ok 併發：兩個連線同時 set_album_children 覆蓋同一本相簿的孩子標記，終態正確是後 commit 那一方的完整集合，沒有混合';
end;
$$;
