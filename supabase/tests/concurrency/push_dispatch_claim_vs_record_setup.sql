-- LS-172 R2（merge-reviewer i5，情境二）：claim_notification_events() 跟
-- record_notification_event()（既有 LS-58 trigger，5 分鐘視窗彙總）幾乎同時碰
-- 同一個目標——claim 進行中時新事件進來，不該混進同一筆已 claim 的列，而是開新列。
--
-- **本機實測修正**：兩支函式的 occurred_at 條件（claim 要 `< now()-5min`、record
-- 要 `>= now()-5min`）對同一個 `now()` 求值是嚴格互補、零重疊的——本來預期的
-- 「record 的 SELECT ... FOR UPDATE 被 claim 鎖住的列卡住、EvalPlanQual 重新檢查」
-- 實測發現根本不會發生：record 的候選 SELECT 在掃描階段就已經被 occurred_at 條件
-- 排除掉這一列，從未嘗試對它取鎖。真正保護這個不變量的是 occurred_at 過濾本身，
-- 不是鎖——這裡仍然用真正並行的兩個 session 驗證最終狀態正確，理由與完整分析見
-- push_dispatch_claim_vs_record_s2_comment.sql 檔頭。
--
-- 種子資料：一筆已穩定（10 分鐘前）、sent_at is null 的「comment/diary」事件 X，
-- target_id 是一個孤兒 id（不對應任何真正的 diaries 列——create_comment() 允許
-- 孤兒 target_id，見 private.target_family_id() 的既有裁量），S1 用
-- claim_notification_events() claim 走 X 並壓住交易；S2 用真正的 create_comment()
-- RPC（跟 production 呼叫路徑一致，不是直接操作 notification_events）對同一
-- target_id 建立一則新留言，觸發 notify_comment_created() → record_notification_
-- event()。

\set ON_ERROR_STOP on

delete from public.notification_events where sent_at is null;
delete from public.comments where family_id = 'c2000000-0000-4000-8000-000000000002';

drop table if exists public.ls172_claim_vs_record_capture;
create table public.ls172_claim_vs_record_capture (
  session text not null,
  claimed_id uuid
);
-- S1 以 service_role 呼叫 claim_notification_events()、S2 以 authenticated 呼叫
-- create_comment()，兩邊都會把結果寫進這張表——同 push_dispatch_claim_race_setup.sql
-- 的既有理由，新表對這兩個角色都要明確 grant（harden_default_privileges.sql 已把
-- PUBLIC baseline 收掉）。
grant insert, select on public.ls172_claim_vs_record_capture to service_role, authenticated;

delete from public.families where id = 'c2000000-0000-4000-8000-000000000002';
delete from auth.users where id in (
  'c1000000-0000-4000-8000-000000000011',
  'c1000000-0000-4000-8000-000000000012'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('c1000000-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'c2-owner@ls172race.test', now(), now(), '{}', '{}'),
  ('c1000000-0000-4000-8000-000000000012', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'c2-commenter@ls172race.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('c1000000-0000-4000-8000-000000000011', 'LS172 claim-vs-record owner'),
  ('c1000000-0000-4000-8000-000000000012', 'LS172 claim-vs-record commenter')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.families (id, name, created_by) values
  ('c2000000-0000-4000-8000-000000000002', 'LS172 claim-vs-record 測試家', 'c1000000-0000-4000-8000-000000000011');

insert into public.family_members (family_id, user_id, role) values
  ('c2000000-0000-4000-8000-000000000002', 'c1000000-0000-4000-8000-000000000012', 'member')
on conflict do nothing; -- owner 已由 families 的 AFTER INSERT trigger 自動塞入

-- 事件 X：已穩定、待 claim；kind/target_type/target_id 跟 S2 即將建立的新留言
-- 完全一致，才會是同一個合併鍵。
insert into public.notification_events
  (id, family_id, kind, target_type, target_id, actor_id, event_count, occurred_at)
values (
  'c5000000-0000-4000-8000-000000000001',
  'c2000000-0000-4000-8000-000000000002',
  'comment', 'diary', 'c4000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000011',
  1,
  now() - interval '10 minutes'
);

do $$
declare
  v_n int;
begin
  select count(*) into v_n from public.notification_events
   where id = 'c5000000-0000-4000-8000-000000000001' and sent_at is null;
  if v_n <> 1 then
    raise exception 'SETUP FAIL：事件 X 應該存在且待送，實際 %', v_n;
  end if;
  raise notice 'ok setup：事件 X 就緒（10 分鐘前、待 claim）';
end;
$$;
