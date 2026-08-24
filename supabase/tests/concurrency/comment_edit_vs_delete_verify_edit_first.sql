-- 併發場景（方向 A：編輯先動）的最終狀態斷言：兩個動作都必須真的生效、未互相
-- 覆蓋。理由同 album_edit_vs_delete_verify_edit_first.sql。

\set ON_ERROR_STOP on

do $$
declare
  v_body text;
  v_deleted timestamptz;
begin
  select c.body, c.deleted_at into v_body, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_body <> '編輯先動的新留言' then
    raise exception 'FAIL 併發：最終 body 不是作者編輯後的內容（實際「%」）', v_body;
  end if;
  if v_deleted is null then
    raise exception 'FAIL 併發：owner 的軟刪最終沒有生效';
  end if;

  raise notice 'ok 併發：最終狀態一致（編輯內容已落地＝「%」，且已軟刪）', v_body;
end;
$$;
