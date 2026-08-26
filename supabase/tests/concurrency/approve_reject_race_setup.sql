-- LS-33 併發場景二「同一筆申請被同時核准與拒絕」的場景資料。
--
-- 形狀是刻意的：一個家庭兩位 owner（PLAN §3：爸媽各一個 owner 是常態），
-- 一筆 pending 申請。爸爸按核准的同時媽媽按拒絕，是真的會發生的操作。
--
-- 申請列直接寫死（不走 request_join）：兩個 session 要對「同一個 request_id」動作，
-- 隨機產生的 id 傳不進去。以 postgres 身分直接寫表是 setup 的正當作法（繞過 RLS）。

\set ON_ERROR_STOP on

delete from public.families where id = 'ff000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'eb000000-0000-4000-8000-000000000001',
  'eb000000-0000-4000-8000-000000000002',
  'eb000000-0000-4000-8000-000000000003'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('eb000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'eb-owner1@ls33.test',   now(), now(), '{}', '{}'),
  ('eb000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'eb-owner2@ls33.test',   now(), now(), '{}', '{}'),
  ('eb000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'eb-applicant@ls33.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('eb000000-0000-4000-8000-000000000001', '審核競態家 爸爸'),
  ('eb000000-0000-4000-8000-000000000002', '審核競態家 媽媽'),
  ('eb000000-0000-4000-8000-000000000003', '等待審核的申請人')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.families (id, name, created_by) values
  ('ff000000-0000-4000-8000-000000000001', '審核競態家', 'eb000000-0000-4000-8000-000000000001');

insert into public.family_members (family_id, user_id, role) values
  ('ff000000-0000-4000-8000-000000000001', 'eb000000-0000-4000-8000-000000000002', 'owner');

insert into public.invites (id, family_id, code, role, created_by, max_uses, used_count, expires_at)
values ('1f000000-0000-4000-8000-000000000001', 'ff000000-0000-4000-8000-000000000001',
        'RACE6789', 'member', 'eb000000-0000-4000-8000-000000000001', 1, 1,
        now() + interval '7 days');

insert into public.join_requests (id, family_id, invite_id, applicant_id, status) values
  ('9f000000-0000-4000-8000-000000000001', 'ff000000-0000-4000-8000-000000000001',
   '1f000000-0000-4000-8000-000000000001', 'eb000000-0000-4000-8000-000000000003', 'pending');

do $$
declare
  v_owners int;
  v_status public.join_request_status;
begin
  select count(*) into v_owners from public.family_members
   where family_id = 'ff000000-0000-4000-8000-000000000001' and role = 'owner';
  select r.status into v_status from public.join_requests r
   where r.id = '9f000000-0000-4000-8000-000000000001';
  if v_owners <> 2 then
    raise exception 'SETUP FAIL：審核競態家應有 2 位 owner，實際 %', v_owners;
  end if;
  if v_status <> 'pending' then
    raise exception 'SETUP FAIL：申請應為 pending，實際 %', v_status;
  end if;
  raise notice 'ok setup：審核競態家有 2 位 owner 與 1 筆 pending 申請';
end;
$$;
