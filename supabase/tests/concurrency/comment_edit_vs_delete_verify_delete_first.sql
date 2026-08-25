-- 併發場景（方向 B：軟刪先動）的最終狀態斷言。理由同
-- album_edit_vs_delete_verify_delete_first.sql。

\set ON_ERROR_STOP on

do $$
declare
  v_body text;
  v_deleted timestamptz;
begin
  select c.body, c.deleted_at into v_body, v_deleted from public.comments c
   where c.id = '69000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：先 commit 的軟刪被推翻了（deleted_at 竟然是 NULL）';
  end if;
  if v_body <> '軟刪之後還想改' then
    raise exception 'FAIL 併發：作者的編輯最終沒有落地（body=「%」）——序列化沒有生效，其中一邊的寫入被覆蓋掉了', v_body;
  end if;

  raise notice 'ok 併發：軟刪先動時最終 deleted_at 已設定，body 也是作者後來編輯的內容（兩者皆生效，未互相覆蓋）';
end;
$$;
