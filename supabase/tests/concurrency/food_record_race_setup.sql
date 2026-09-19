-- LS-325 併發場景「兩個連線同時 upsert_child_food_record 同一寶貝同一食物」的
-- 場景資料。
--
-- 形狀：一個家庭，一位作者（owner）。一個孩子。S1／S2 皆以同一位作者身分對同一寶貝
-- 同一食物（'banana'）呼叫 upsert_child_food_record——S1 先動並壓住 3 秒不 commit，
-- S2 等 1.2 秒後才動，必須被 S1 持有的（隱含於 ON CONFLICT 衝突偵測的）鎖阻塞，
-- 解除阻塞後看到 S1 已 commit 的列、轉為更新，終態必須恰好一列、內容是 S2（後
-- commit 那方）寫入的值。見 20260918205141_food_encyclopedia.sql 檔頭第 0 段 a 的
-- 設計說明——這裡把該推導提升成常駐、可重跑的併發 regression test。

\set ON_ERROR_STOP on

delete from public.families where id = '71000000-0000-4000-8000-000000000001';
delete from auth.users where id = '72000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('72000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'food-record-race-author@ls325.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('72000000-0000-4000-8000-000000000001', '飲食記錄競態家 作者')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner；作者本人就是 owner。
insert into public.families (id, name, created_by) values
  ('71000000-0000-4000-8000-000000000001', '飲食記錄競態家', '72000000-0000-4000-8000-000000000001');

insert into public.children (id, family_id, name, birthday) values
  ('73000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000001', '競態寶寶', date '2024-01-01');

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.child_food_records
   where child_id = '73000000-0000-4000-8000-000000000001' and food_id = 'banana';
  if v_n <> 0 then
    raise exception 'SETUP FAIL：飲食記錄競態家初始應無 banana 紀錄，實際 %', v_n;
  end if;
  raise notice 'ok setup：飲食記錄競態家就緒，尚無 banana 紀錄';
end;
$$;
