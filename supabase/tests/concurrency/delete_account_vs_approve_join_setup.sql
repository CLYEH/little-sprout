-- LS-143 R2（merge-review R1 m2）併發場景的場景資料：一個目前只有唯一成員 A（也是
-- 唯一 owner）的家庭，加上一支已核發的邀請碼（role=owner）與一筆該邀請碼底下的
-- pending 申請人 C。
--
-- 形狀是刻意的：R1 m2 指出的競態需要「A 呼叫 delete_my_account() 時，這個家庭剛好
-- 是 A 的唯一成員」且「同時有人在核准一筆申請」——而能核准申請的只有該家庭的
-- owner，這裡就是 A 本人（單成員家庭沒有別人能當 owner）。所以 S1／S2 兩個連線
-- 都以 A 的身分登入，模擬「A 用兩支裝置，一支在按核准、另一支在刪帳號」。
--
-- 邀請碼的 role 刻意選 'owner'（不是預設的 'member'）：這樣核准之後家庭會有 A、C
-- 兩位 owner，A 接著在情況 3 離開家庭時不會撞上既有的 owner 不變量 trigger（那是
-- 另一組已經測過的併發場景，見 owner_guard_*／delete_account_race_*，這裡不重複
-- 測，只想乾淨地驗 m2 本身：A 解鎖後必須改走情況 3、C 必須還在）。
--
-- 每個場景開始前都重跑一次（前一個場景會 commit，不能靠 rollback 還原）。

\set ON_ERROR_STOP on

delete from public.families where id = 'd5000000-0000-4000-8000-000000000001';
delete from auth.users where id in (
  'd6000000-0000-4000-8000-000000000001',
  'd7000000-0000-4000-8000-000000000001'
);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('d6000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls143-vs-owner@ls143.test', now(), now(), '{}', '{}'),
  ('d7000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'ls143-vs-applicant@ls143.test', now(), now(), '{}', '{}');

insert into public.profiles (id, display_name) values
  ('d6000000-0000-4000-8000-000000000001', 'LS143 vs-approve owner'),
  ('d7000000-0000-4000-8000-000000000001', 'LS143 vs-approve applicant')
on conflict (id) do update set display_name = excluded.display_name;

-- created_by 由 add_creator_as_owner trigger 寫成第一位（也是目前唯一一位）owner
insert into public.families (id, name, created_by) values
  ('d5000000-0000-4000-8000-000000000001', 'LS143 vs-approve 測試家', 'd6000000-0000-4000-8000-000000000001');

insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at) values
  ('d8000000-0000-4000-8000-000000000001', 'd5000000-0000-4000-8000-000000000001',
   'LS143VSAJ', 'owner', 'd6000000-0000-4000-8000-000000000001', 1, now() + interval '7 days');

insert into public.join_requests (id, family_id, invite_id, applicant_id, status) values
  ('d9000000-0000-4000-8000-000000000001', 'd5000000-0000-4000-8000-000000000001',
   'd8000000-0000-4000-8000-000000000001', 'd7000000-0000-4000-8000-000000000001', 'pending');

do $$
declare
  v_members int;
  v_status public.join_request_status;
begin
  select count(*) into v_members from public.family_members
   where family_id = 'd5000000-0000-4000-8000-000000000001';
  select r.status into v_status from public.join_requests r
   where r.id = 'd9000000-0000-4000-8000-000000000001';
  if v_members <> 1 then
    raise exception 'SETUP FAIL：LS143 vs-approve 測試家應恰好 1 位成員（唯一 owner A），實際 %', v_members;
  end if;
  if v_status <> 'pending' then
    raise exception 'SETUP FAIL：申請應為 pending，實際 %', v_status;
  end if;
  raise notice 'ok setup：LS143 vs-approve 測試家有 1 位唯一成員／owner，1 筆 pending 申請（role=owner）';
end;
$$;
