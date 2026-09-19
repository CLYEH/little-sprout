-- LS-342：sort_order deferrable unique 正面探針。
--
-- 重現 20260919073805_food_catalog_expansion.sql 交易中段那種「INSERT 在前、UPDATE
-- 在後」造成的跨陳述式暫時重複（LS-96 池項 708422e5 i1）：插入一列暫時撞號
-- rice_cereal（sort_order=1），下一句 UPDATE 才把 rice_cereal 移開解除重複，最後
-- 刪除臨時列、把 rice_cereal 移回原值。全程包在同一個交易內，COMMIT 應該成功——
-- 證明 deferred unique constraint 不會擋下這種既有的重排模式。
\set ON_ERROR_STOP on

begin;

insert into public.food_catalog (id, name_zh, category, sort_order)
values ('ls342_probe_reorder', 'LS342 探針', 'grain_root', 1);  -- 與 rice_cereal(1) 暫時重複

update public.food_catalog set sort_order = 999999 where id = 'rice_cereal';  -- 移開解除重複

delete from public.food_catalog where id = 'ls342_probe_reorder';

update public.food_catalog set sort_order = 1 where id = 'rice_cereal';  -- 移回原值

commit;

do $$
begin
  raise notice 'ok：交易內跨陳述式的暫時重複 sort_order（INSERT 在前、UPDATE 在後）COMMIT 成功，deferred unique 未擋下既有重排模式';
end;
$$;
