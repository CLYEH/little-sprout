-- 併發場景（方向 C：作者搬家先動）的最終狀態斷言：留言必須真的搬到 f9，且
-- deleted_at 必須維持 NULL。理由同 album_edit_vs_delete_verify_move_blocked.sql。

\set ON_ERROR_STOP on

do $$
declare
  v_family uuid;
  v_deleted timestamptz;
begin
  select c.family_id, c.deleted_at into v_family, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_family <> 'f9000000-0000-4000-8000-000000000001' then
    raise exception 'FAIL 併發：作者的搬家最終沒有生效（family_id=%）', v_family;
  end if;
  if v_deleted is not null then
    raise exception 'FAIL 併發：留言的 deleted_at 竟然被設定了（%）——f4 owner 對已搬到 f9 的留言完成了軟刪，跨家庭越權', v_deleted;
  end if;

  raise notice 'ok 併發：留言已搬到 f9，deleted_at 維持 NULL（f4 owner 的軟刪被正確擋下，沒有跨家庭越權）';
end;
$$;
