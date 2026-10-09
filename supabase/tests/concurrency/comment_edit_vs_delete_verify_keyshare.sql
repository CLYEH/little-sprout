-- 鎖強度探針（LS-435）的最終狀態斷言：session 1 只佔 FOR KEY SHARE、不改資料，
-- session 2 的 set_comment_deleted 在鎖釋放後成功軟刪。所以終態必須是「已軟刪、body維持原始內容」。
--
-- 不能沿用 comment_edit_vs_delete_verify_delete_first.sql / _edit_first.sql：那兩支期待作者的編輯
-- 已落地（body是編輯後的內容），而探針這組沒有任何編輯。

\set ON_ERROR_STOP on

do $$
declare
  v_body text;
  v_deleted timestamptz;
begin
  select c.body, c.deleted_at into v_body, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：owner 的軟刪最終沒有生效（deleted_at 是 NULL）';
  end if;
  if v_body <> '原始留言' then
    raise exception 'FAIL 併發：探針不改資料，body卻變成「%」', v_body;
  end if;

  raise notice 'ok 併發：鎖強度探針終態一致（已軟刪，body維持原始內容）';
end;
$$;
