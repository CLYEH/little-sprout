-- LS-172 R2（merge-reviewer i5，情境一）：兩個真正並行的 claim_notification_events()
-- 呼叫，claim 到的事件集合交集必須是空集合（不會重疊）。
--
-- 形狀：10 筆彼此獨立、皆已穩定（occurred_at 10 分鐘前，早過 5 分鐘視窗）、
-- sent_at is null 的事件。S1／S2 各自呼叫 p_limit=5——如果 FOR UPDATE SKIP LOCKED
-- 正確運作，兩邊應該恰好瓜分這 10 筆、完全不重疊；S1 用 pg_sleep 撐住交易不 commit，
-- 逼出真正的併發窗口（不然兩個呼叫太快，測不出「同時進行」這件事本身）。
--
-- 先清空全部待送事件（不只是本場景自己的）：claim_notification_events() 是全域
-- 佇列查詢，沒有 family 過濾，若這次 supabase db reset 之後、跑到這個測試檔之前
-- 已經有其他測試留下委託且未 rollback 的 sent_at is null 舊資料，會讓「恰好瓜分
-- 10 筆」這個斷言失真——這裡的清空範圍刻意比其他併發場景的 setup 更大，是
-- claim_notification_events() 全域查詢語意的必要結果，不是隨便擴權。
--
-- 每個場景開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.notification_events where sent_at is null;

drop table if exists public.ls172_claim_race_capture;
create table public.ls172_claim_race_capture (
  session text not null,
  event_id uuid not null,
  -- LS-96 池項 8519d8a4 第 2 條（merge-review R2-i2）：「不重疊」這個斷言本身
  -- 不會被拿掉 SKIP LOCKED（改成單純 FOR UPDATE）的 mutation 打中——reviewer
  -- 實測過拿掉 SKIP LOCKED 之後 S2 會被 S1 卡住、S1 commit 後 EvalPlanQual 重
  -- 檢把已標記的列濾掉、繼續掃到剩下的 5 筆，最終集合依然不重疊。真正該釘住
  -- 的是「S2 沒有被卡住」這個耗時特徵，只有 S2 會寫這一欄（S1 維持 NULL）。
  claim_duration_ms numeric
);
-- S1／S2 都是以 service_role 呼叫 claim_notification_events() 之後在同一句
-- INSERT...SELECT 裡把結果寫進這張表——這張表是這個測試檔自己建立的、不是任何
-- migration 管的正式 schema，`harden_default_privileges.sql` 的全域 default
-- privileges 已經把新表對 service_role 的 PUBLIC baseline 收掉，不明確 grant
-- 會撞 permission denied（本機實測踩出）。
grant insert, select, update on public.ls172_claim_race_capture to service_role;

delete from public.families where id = 'c2000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'c1000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000002'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('c1000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'c1-owner@ls172race.test', now(), now(), '{}', '{}'),
  ('c1000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'c1-actor@ls172race.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('c1000000-0000-4000-8000-000000000001', 'LS172 claim race owner'),
  ('c1000000-0000-4000-8000-000000000002', 'LS172 claim race actor')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.families (id, name, created_by) values
  ('c2000000-0000-4000-8000-000000000001', 'LS172 claim race 測試家', 'c1000000-0000-4000-8000-000000000001');

-- 10 筆獨立事件（各自不同 target_id，避免 record_notification_event 的合併邏輯
-- 把它們併成一筆——這裡就是要 10 筆各自獨立的待送列）。
insert into public.notification_events
  (id, family_id, kind, target_type, target_id, actor_id, event_count, occurred_at)
select
  ('c3000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  'c2000000-0000-4000-8000-000000000001',
  'diary',
  'diary',
  gen_random_uuid(),
  'c1000000-0000-4000-8000-000000000002',
  1,
  now() - interval '10 minutes'
from generate_series(1, 10) as n;

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.notification_events
   where family_id = 'c2000000-0000-4000-8000-000000000001' and sent_at is null;
  if v_n <> 10 then
    raise exception 'SETUP FAIL：應該有 10 筆待送事件，實際 %', v_n;
  end if;
  raise notice 'ok setup：10 筆獨立待送事件就緒，全域待送佇列已清空避免污染';
end;
$$;
