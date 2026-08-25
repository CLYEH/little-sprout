-- 併發場景（方向 A：編輯先動）的最終狀態斷言：編輯的內容必須先落地，軟刪才發生。
--
-- 只斷言「兩個動作都成功」是不夠的——若 update_child 沒有真的鎖住這一列，兩個
-- session 的時序就無法保證，這裡直接寫死「name 必須是編輯後的內容，且已軟刪」，
-- 而不只是「兩者皆非空」這種鬆散的一致性檢查。

\set ON_ERROR_STOP on

do $$
declare
  v_name text;
  v_deleted timestamptz;
begin
  select c.name, c.deleted_at into v_name, v_deleted from public.children c
   where c.id = '29000000-0000-4000-8000-000000000001';

  if v_name <> '編輯先動的新名字' then
    raise exception 'FAIL 併發：最終 name 不是 member 編輯後的內容（實際「%」）', v_name;
  end if;
  if v_deleted is null then
    raise exception 'FAIL 併發：owner 的軟刪最終沒有生效';
  end if;

  raise notice 'ok 併發：最終狀態一致（編輯內容已落地＝「%」，且已軟刪）', v_name;
end;
$$;
