-- LS-153 併發場景「purge_expired() 硬刪 vs set_child_deleted(false) 還原同一個孩子」
-- 的場景資料。形狀比照 children_edit_vs_delete_setup.sql（LS-66）：一個家庭一位
-- owner，孩子直接寫死 id（兩個 session 要對「同一個孩子檔案」動作，隨機產生的 id
-- 傳不進去，以 postgres 身分直接寫表是 setup 的正當作法）。
--
-- p_now 用固定字面值（不是 clock_timestamp()）：setup 與 s1 是兩個各自獨立的 psql
-- 呼叫，沒有共用變數的方式，只能靠寫死同一個值讓兩邊對齊「deleted_at 是 31 天前」
-- 這件事。
--
-- 每個方向開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'f9000000-0000-4000-8000-000000000001';
delete from auth.users where id = 'b9000000-0000-4000-8000-000000000001';

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('b9000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'purge-race-owner@ls153.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('b9000000-0000-4000-8000-000000000001', 'Purge 競態家 owner')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('f9000000-0000-4000-8000-000000000001', 'Purge 競態家', 'b9000000-0000-4000-8000-000000000001');

-- deleted_at 固定寫成「p_now（2026-09-03 00:00:00+00，s1 呼叫 purge_expired 用同一個
-- 值）往前 31 天」，超過 30 天保護窗——purge 該清，還原該被拒。
insert into public.children (id, family_id, name, birthday, deleted_at) values
  ('2f000000-0000-4000-8000-000000000001', 'f9000000-0000-4000-8000-000000000001',
   '競態孩子', date '2023-01-01',
   timestamptz '2026-09-03 00:00:00+00' - interval '31 days');

do $$
declare
  v_deleted timestamptz;
begin
  select c.deleted_at into v_deleted from public.children c
   where c.id = '2f000000-0000-4000-8000-000000000001';
  if v_deleted is null then
    raise exception 'SETUP FAIL：競態孩子的 deleted_at 沒有設定成功';
  end if;
  raise notice 'ok setup：Purge 競態家已建立，孩子檔案 deleted_at=%（31 天前，超過保護窗）', v_deleted;
end;
$$;
