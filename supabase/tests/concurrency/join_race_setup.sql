-- LS-33 併發場景一「兩個人同時搶邀請碼的最後一個名額」的場景資料。
--
-- 形狀是刻意的：max_uses = 1、used_count = 0，兩位申請人都還不是成員。
-- 單一 session 內測不出這個洞——要重現的時序需要兩個交易同時開著。
--
-- 邀請碼直接寫死（不呼叫 create_invite）：兩個 psql session 必須用同一支碼，
-- 而 create_invite 產出的是隨機碼。'RACE2345' 完全落在 create_invite 的字元集
-- （23456789ABCDEFGHJKLMNPQRSTUVWXYZ）內，所以 request_join 的正規化比對認得它。
--
-- 每個場景開始前都重跑一次（場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'fe000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000002',
  'ea000000-0000-4000-8000-000000000003'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('ea000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ea-owner@ls33.test',     now(), now(), '{}', '{}'),
  ('ea000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ea-applicant1@ls33.test', now(), now(), '{}', '{}'),
  ('ea000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ea-applicant2@ls33.test', now(), now(), '{}', '{}');

-- LS-110：auth.users insert 已觸發 trigger 自動建立 profiles，這裡蓋成固定名稱。
insert into public.profiles (id, display_name) values
  ('ea000000-0000-4000-8000-000000000001', '名額競態家 owner'),
  ('ea000000-0000-4000-8000-000000000002', '搶名額的甲'),
  ('ea000000-0000-4000-8000-000000000003', '搶名額的乙')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成 owner
insert into public.families (id, name, created_by) values
  ('fe000000-0000-4000-8000-000000000001', '名額競態家', 'ea000000-0000-4000-8000-000000000001');

insert into public.invites (id, family_id, code, role, created_by, max_uses, used_count, expires_at)
values ('1e000000-0000-4000-8000-000000000001', 'fe000000-0000-4000-8000-000000000001',
        'RACE2345', 'member', 'ea000000-0000-4000-8000-000000000001', 1, 0,
        now() + interval '7 days');

do $$
declare
  v_used int;
  v_max int;
  v_require boolean;
begin
  select i.used_count, i.max_uses into v_used, v_max
    from public.invites i where i.code = 'RACE2345';
  select f.require_approval into v_require from public.families f
   where f.id = 'fe000000-0000-4000-8000-000000000001';
  if v_used <> 0 or v_max <> 1 then
    raise exception 'SETUP FAIL：邀請碼應為 0/1，實際 %/%', v_used, v_max;
  end if;
  if not v_require then
    raise exception 'SETUP FAIL：家庭應為需要審核（require_approval 預設 true）';
  end if;
  raise notice 'ok setup：名額競態家的邀請碼剩 1 個名額，兩位申請人待命';
end;
$$;
