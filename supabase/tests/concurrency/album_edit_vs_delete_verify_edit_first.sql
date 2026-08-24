-- 併發場景（方向 A：編輯先動）的最終狀態斷言：兩個動作都必須真的生效，且沒有
-- 互相覆蓋掉對方寫的欄位——這是這組併發測試實際能證明的事（見 s2_delete.sql
-- 檔頭：albums 沒有「已軟刪除不能編輯」的規則，所以兩個動作不是互斥關係，而是
-- 都該落地）。

\set ON_ERROR_STOP on

do $$
declare
  v_title text;
  v_deleted timestamptz;
begin
  select a.title, a.deleted_at into v_title, v_deleted from public.albums a
   where a.id = '49000000-0000-4000-8000-000000000001';

  if v_title <> '編輯先動的新標題' then
    raise exception 'FAIL 併發：最終 title 不是作者編輯後的內容（實際「%」）', v_title;
  end if;
  if v_deleted is null then
    raise exception 'FAIL 併發：owner 的軟刪最終沒有生效';
  end if;

  raise notice 'ok 併發：最終狀態一致（編輯內容已落地＝「%」，且已軟刪）', v_title;
end;
$$;
