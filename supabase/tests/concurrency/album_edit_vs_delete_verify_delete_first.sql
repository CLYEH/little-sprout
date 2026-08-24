-- 併發場景（方向 B：軟刪先動）的最終狀態斷言：兩個動作都必須真的生效——跟方向 A
-- 的最終狀態其實相同（見 s2_update.sql 檔頭：albums 沒有互斥規則），這裡刻意用
-- 反方向重跑一次是為了驗到 set_album_deleted 尾端 UPDATE 自己的鎖（見
-- s1_delete.sql 的說明），不是為了得到不同的最終狀態。

\set ON_ERROR_STOP on

do $$
declare
  v_title text;
  v_deleted timestamptz;
begin
  select a.title, a.deleted_at into v_title, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_deleted is null then
    raise exception 'FAIL 併發：先 commit 的軟刪被推翻了（deleted_at 竟然是 NULL）';
  end if;
  if v_title <> '軟刪之後還想改' then
    raise exception 'FAIL 併發：作者的編輯最終沒有落地（title=「%」）——序列化沒有生效，其中一邊的寫入被覆蓋掉了', v_title;
  end if;

  raise notice 'ok 併發：軟刪先動時最終 deleted_at 已設定，title 也是作者後來編輯的內容（兩者皆生效，未互相覆蓋）';
end;
$$;
