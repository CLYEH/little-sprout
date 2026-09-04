-- LS-179（LS-23 後端切片）— 使用者／家庭停權旗標＋註冊開關
--
-- 對應 migration 20260904212530_suspension_and_registrations.sql。沿用
-- 00_fixtures.sql 的固定家庭／使用者（A 家：owner a1／member a2／viewer a3；
-- B 家：owner b1／member b2；C 家＝效能測試家，owner c1）。
--
-- 每個場景各自 begin/rollback，互不污染 fixtures（比照本目錄既有慣例）。
-- R2（merge-review R1 `23fa5e37`）新增場景 8–14，修正場景 1–7 不再寫
-- `suspended_reason`（MAJOR-1：那一欄已搬到 private.suspension_notes，不再是
-- profiles／families 的欄位）。

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 場景 1：使用者停權 —— SELECT 全面拒絕，其他人不受影響
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：被停權的使用者竟然還看得到 family_members（% 列）', n;
  end if;

  select count(*) into n from public.media
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：被停權的使用者竟然還看得到 media（% 列）', n;
  end if;

  reset role;
  raise notice 'ok：使用者停權後 family_members／media 皆讀不到（0 列）';
end;
$$;

do $$
declare
  n int;
begin
  -- 其他人（a1，未停權）不受影響：仍看得到完整的 3 位成員
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 3 then
    raise exception 'FAIL：a1 不該受 a2 停權影響，family_members 應仍是 3 列，實際 %', n;
  end if;

  reset role;
  raise notice 'ok：家庭其他成員不受單一使用者停權影響（family_members 仍 3 列）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 2：使用者停權 —— 直接寫入與 RPC 入口皆拒絕，回自訂碼 LS052
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 直接寫入（a2 停權前是 can_upload=true 的 member，本來上傳得了）
  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fa000000-0000-4000-8000-000000000001',
            'fa000000-0000-4000-8000-000000000001/2026/09/suspended.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：被停權的使用者竟然可以直接上傳照片';
  exception when sqlstate 'LS052' then
    null; -- ok
  end;

  -- RPC 入口（create_comment，SECURITY DEFINER，繞過 RLS，靠 enforce_not_suspended trigger 擋）
  begin
    perform public.create_comment('fa000000-0000-4000-8000-000000000001', 'media',
      '3a000000-0000-4000-8000-000000000001', '被停權的人想留言');
    raise exception 'FAIL：被停權的使用者竟然可以呼叫 create_comment';
  exception when sqlstate 'LS052' then
    null; -- ok
  end;

  -- RPC 入口（create_child）
  begin
    perform public.create_child('fa000000-0000-4000-8000-000000000001', '測試', date '2024-01-01', null);
    raise exception 'FAIL：被停權的使用者竟然可以呼叫 create_child';
  exception when sqlstate 'LS052' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：使用者停權後直接寫入與 create_comment／create_child RPC 皆拒絕並回 LS052';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 3：解除停權後恢復
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';
update public.profiles set suspended_at = null
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  n int;
  v_comment uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 3 then
    raise exception 'FAIL：解除停權後仍讀不到 family_members（% 列，期望 3）', n;
  end if;

  select public.create_comment('fa000000-0000-4000-8000-000000000001', 'media',
    '3a000000-0000-4000-8000-000000000001', '解除停權後的留言') into v_comment;
  if v_comment is null then
    raise exception 'FAIL：解除停權後 create_comment 沒有成功';
  end if;

  reset role;
  raise notice 'ok：解除停權後讀取與 create_comment 皆恢復正常';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 4：家庭停權 —— 全部成員（含未被個別停權的本人）被拒絕，其他家庭不受影響
-- ---------------------------------------------------------------------------
begin;

update public.families set suspended_at = now()
 where id = 'fb000000-0000-4000-8000-000000000001';

do $$
declare
  n int;
begin
  -- b1 本人未被個別停權，但所屬的 B 家已停權——讀取一樣被擋
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'b0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fb000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：家庭停權後 owner 竟然還看得到 family_members（% 列）', n;
  end if;

  -- RPC 入口一樣被擋，回 LS053（不是 LS052——呼叫者本人沒有被停權）
  begin
    perform public.create_diary_entry('fb000000-0000-4000-8000-000000000001',
      array['2b000000-0000-4000-8000-000000000001']::uuid[], '家庭停權後想寫日記', current_date);
    raise exception 'FAIL：家庭停權後 owner 竟然可以呼叫 create_diary_entry';
  exception when sqlstate 'LS053' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：家庭停權後成員（含未被個別停權者）讀寫皆拒絕並回 LS053';
end;
$$;

do $$
declare
  n int;
begin
  -- 其他家庭（A 家）完全不受影響
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 3 then
    raise exception 'FAIL：B 家停權不該影響 A 家，family_members 應仍是 3 列，實際 %', n;
  end if;

  reset role;
  raise notice 'ok：其他家庭（A 家）不受 B 家停權影響';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 5：三支唯讀 DEFINER RPC 之一（list_comments）的明確檢查
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.list_comments('fa000000-0000-4000-8000-000000000001', 'media',
      '3a000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：被停權的使用者竟然可以呼叫 list_comments';
  exception when sqlstate 'LS052' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：list_comments 對停權的呼叫者回 LS052（唯讀 DEFINER RPC，不靠 RLS／trigger）';
end;
$$;

rollback;

begin;

update public.families set suspended_at = now()
 where id = 'fa000000-0000-4000-8000-000000000001';

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    perform public.list_comments('fa000000-0000-4000-8000-000000000001', 'media',
      '3a000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：家庭停權後 owner 竟然可以呼叫 list_comments';
  exception when sqlstate 'LS053' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：list_comments 對停權的家庭回 LS053';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 6：registrations_open = false —— 只擋自建新家庭，既有成員與憑邀請碼加入不受影響
-- ---------------------------------------------------------------------------
begin;

update public.app_settings set registrations_open = false, updated_at = now() where id = true;

do $$
begin
  -- c1（效能測試帳號的 owner，未停權、也不是任何其他家庭成員）想自建新家庭
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'c0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.families (name, created_by) values ('關站期間想建的家', 'c0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：registrations_open=false 時竟然還能自建新家庭';
  exception when sqlstate 'LS054' then
    null; -- ok
  end;

  reset role;
  raise notice 'ok：registrations_open=false 時自建新家庭被拒絕並回 LS054';
end;
$$;

-- 自建一支純英數的邀請碼（不用 fixture 的 'LS6-AAA-INVITE'——那支帶連字號，
-- request_join 會先正規化輸入再比對 invites.code 原始值，帶連字號的字面值
-- 永遠不會命中，比照 92_delete_account_edge_guard.sql 同型情境的既有處理方式）。
insert into public.invites (id, family_id, code, role, created_by, max_uses, expires_at) values
  ('19000000-0000-4000-8000-000000000001', 'fa000000-0000-4000-8000-000000000001',
   'LS179REG', 'member', 'a0000000-0000-4000-8000-000000000001', 3, now() + interval '7 days');

do $$
declare
  n int;
begin
  -- 既有成員的一般操作不受影響
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 3 then
    raise exception 'FAIL：registrations_open=false 不該影響既有家庭的讀取，實際 % 列', n;
  end if;

  reset role;

  -- 憑邀請碼加入既有家庭（request_join 不碰 families 表）不受影響
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'c0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.request_join('LS179REG');

  reset role;
  raise notice 'ok：registrations_open=false 時既有成員操作與憑邀請碼加入皆不受影響';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 7：notification_recipients() 排除停權使用者
-- ---------------------------------------------------------------------------
begin;

insert into public.device_tokens (token, user_id) values
  ('ls179-token-a002', 'a0000000-0000-4000-8000-000000000002');

do $$
declare
  v_event uuid;
  n int;
begin
  insert into public.notification_events (family_id, kind, target_type, target_id, actor_id, occurred_at)
  values ('fa000000-0000-4000-8000-000000000001', 'comment', 'media',
          '3a000000-0000-4000-8000-000000000001',
          'a0000000-0000-4000-8000-000000000001', now())
  returning id into v_event;

  -- 停權前：a2 應該在收件人清單裡
  select count(*) into n from public.notification_recipients(array[v_event])
   where user_id = 'a0000000-0000-4000-8000-000000000002';
  if n <> 1 then
    raise exception 'FAIL：停權前 a2 應該在 notification_recipients 清單裡，實際 % 列', n;
  end if;

  update public.profiles set suspended_at = now()
   where id = 'a0000000-0000-4000-8000-000000000002';

  select count(*) into n from public.notification_recipients(array[v_event])
   where user_id = 'a0000000-0000-4000-8000-000000000002';
  if n <> 0 then
    raise exception 'FAIL：停權後 notification_recipients 仍回傳 a2，實際 % 列', n;
  end if;

  raise notice 'ok：notification_recipients() 停權前含 a2、停權後排除 a2';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 8（R2，MAJOR-1）：suspended_reason 搬到 private.suspension_notes 之後
-- ——profiles／families 沒有這個欄位；suspension_notes 只有表擁有者讀得到；
-- suspended_at 本身仍然可讀（刻意，見 migration 註解）。
-- ---------------------------------------------------------------------------
begin;

insert into private.suspension_notes (subject_type, subject_id, reason)
values ('user', 'a0000000-0000-4000-8000-000000000002', '測試用稽核原因');

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  n int;
  v_suspended_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- suspended_at 讀得到（刻意，停權事實本來就會從 LS052 揭露）
  select suspended_at into v_suspended_at from public.profiles
   where id = 'a0000000-0000-4000-8000-000000000002';
  if v_suspended_at is null then
    raise exception 'FAIL：停權者自己應該讀得到 suspended_at';
  end if;

  -- private.suspension_notes 完全讀不到（沒有 table grant，不是 RLS 篩選）
  begin
    perform count(*) from private.suspension_notes;
    raise exception 'FAIL：authenticated 竟然能查詢 private.suspension_notes';
  exception when insufficient_privilege then
    null; -- ok（42501，沒有 table grant，見 migration 第 0b 段）
  end;

  reset role;
  raise notice 'ok：suspended_at 可讀、private.suspension_notes 完全讀不到（MAJOR-1）';
end;
$$;

-- 結構層面釘住：profiles／families 不應該有 suspended_reason 欄位（防止之後
-- 有人不小心把它加回去、繞過本次修法的意圖）。
do $$
declare
  n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public'
     and table_name in ('profiles', 'families')
     and column_name = 'suspended_reason';
  if n <> 0 then
    raise exception 'FAIL：profiles／families 不該有 suspended_reason 欄位（MAJOR-1 已搬到 private.suspension_notes），實際命中 % 個', n;
  end if;
  raise notice 'ok：profiles／families 皆無 suspended_reason 欄位';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 9（R2，m1）：content_reports_select／join_requests_select 的「自己那
-- 一支」分支也要拒絕（票面「全部 policy」，之前只有「owner 那一支」被收斂）
-- ---------------------------------------------------------------------------
begin;

-- fixture 8a：reporter_id = a2，family A
update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.content_reports
   where id = '8a000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：停權者仍讀得到自己送出的 content_reports 列（% 列）', n;
  end if;

  reset role;
  raise notice 'ok：停權後看不到自己送出的 content_reports（reporter_id 分支已補判斷）';
end;
$$;

rollback;

begin;

-- 家庭停權同樣要擋住這個分支（family_is_active）——用同一筆 8a 報告，改停
-- 家庭本身，reporter（a2）本人不停權。
update public.families set suspended_at = now()
 where id = 'fa000000-0000-4000-8000-000000000001';

do $$
declare
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.content_reports
   where id = '8a000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：家庭停權後，未被個別停權的 reporter 仍讀得到自己的 content_reports（% 列）', n;
  end if;

  reset role;
  raise notice 'ok：家庭停權後 content_reports 的 reporter_id 分支也正確拒絕';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 10（R2，MAJOR-2）：delete_my_account() 對停權者／停權家庭成員仍可用
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  v_deletion_requested timestamptz;
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.delete_my_account();

  reset role;

  select deletion_requested_at into v_deletion_requested from public.profiles
   where id = 'a0000000-0000-4000-8000-000000000002';
  if v_deletion_requested is null then
    raise exception 'FAIL：被停權的使用者呼叫 delete_my_account() 之後 deletion_requested_at 仍是 NULL';
  end if;

  select count(*) into n from public.family_members
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and user_id = 'a0000000-0000-4000-8000-000000000002';
  if n <> 0 then
    raise exception 'FAIL：delete_my_account() 之後 a2 應該已離開 A 家';
  end if;

  raise notice 'ok：被停權的使用者仍能成功呼叫 delete_my_account()（App Store 5.1.1(v)）';
end;
$$;

rollback;

begin;

-- 家庭停權、成員本人未被個別停權
update public.families set suspended_at = now()
 where id = 'fb000000-0000-4000-8000-000000000001';

do $$
declare
  v_deletion_requested timestamptz;
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'b0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  perform public.delete_my_account();

  reset role;

  select deletion_requested_at into v_deletion_requested from public.profiles
   where id = 'b0000000-0000-4000-8000-000000000002';
  if v_deletion_requested is null then
    raise exception 'FAIL：停權家庭裡的成員呼叫 delete_my_account() 之後 deletion_requested_at 仍是 NULL';
  end if;

  select count(*) into n from public.family_members
   where family_id = 'fb000000-0000-4000-8000-000000000001'
     and user_id = 'b0000000-0000-4000-8000-000000000002';
  if n <> 0 then
    raise exception 'FAIL：delete_my_account() 之後 b2 應該已離開 B 家';
  end if;

  raise notice 'ok：停權家庭裡未被個別停權的成員仍能成功呼叫 delete_my_account()';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 11（R2，MAJOR-2 防禦）：交易級 GUC 不會跨交易存活——即使假設性地放寬到
-- 「client 自己找得到辦法呼叫 set_config」這個最寬鬆的假設，這個值也只在
-- 設定當下的那個交易內有效，不會讓「下一個獨立 request」的操作被誤放行。
-- 用兩個各自獨立的 begin/commit（不是 begin/rollback）模擬兩個獨立的
-- PostgREST request——這是本檔唯一需要真的 COMMIT 的場景，收尾另外清乾淨。
-- ---------------------------------------------------------------------------
begin;
update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';
select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
set local role authenticated;
select set_config('ls179.account_deletion', 'on', true);
reset role;
commit;

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fa000000-0000-4000-8000-000000000001',
            'fa000000-0000-4000-8000-000000000001/2026/09/guc-bypass-attempt.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：上一個（已 COMMIT 的）交易設的 is_local GUC 竟然跨交易存活，繞過了停權檢查';
  exception when sqlstate 'LS052' then
    null; -- ok：完全沒有跨交易殘留
  end;

  reset role;
  raise notice 'ok：is_local=true 的 GUC 不會跨交易存活——寫入仍正確拿到 LS052（MAJOR-2 防禦）';
end;
$$;

-- 清理：上面是真的 COMMIT，這裡把 a2 的停權狀態復原，不留殘留給後續測試／
-- 併發 regression（這幾支之後才跑）。
update public.profiles set suspended_at = null
 where id = 'a0000000-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------------
-- 場景 12（R2，m3，M4 mutation 存活的回歸保護）：停權者對 storage.objects 的
-- select／insert——這條路徑只靠本檔第 2 段收斂的四支集合函式，沒有 trigger
-- backstop；merge-review R1 的 M4 mutation（拿掉 uploadable_family_ids() 的
-- 兩句停權排除）在補這個測試之前，105／run.sh 全綠、沒有任何測試會抓到它。
-- ---------------------------------------------------------------------------
begin;

insert into storage.objects (bucket_id, name, owner, owner_id) values
  ('media', 'fa000000-0000-4000-8000-000000000001/2026/09/9a000000-0000-4000-8000-000000000001.jpg',
   'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');

do $$
declare
  n int;
begin
  -- 停權前：a2 讀得到自己剛塞的物件
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from storage.objects
   where bucket_id = 'media'
     and name = 'fa000000-0000-4000-8000-000000000001/2026/09/9a000000-0000-4000-8000-000000000001.jpg';
  if n <> 1 then
    raise exception 'FAIL：停權前 a2 應該讀得到自己的 storage.objects 列，實際 % 列', n;
  end if;

  reset role;
end;
$$;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000002';

do $$
declare
  n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from storage.objects
   where bucket_id = 'media'
     and name = 'fa000000-0000-4000-8000-000000000001/2026/09/9a000000-0000-4000-8000-000000000001.jpg';
  if n <> 0 then
    raise exception 'FAIL：停權後 a2 竟然還讀得到自己的 storage.objects 列（% 列）', n;
  end if;

  begin
    insert into storage.objects (bucket_id, name, owner, owner_id) values
      ('media', 'fa000000-0000-4000-8000-000000000001/2026/09/9a000000-0000-4000-8000-000000000002.jpg',
       'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：停權後 a2 竟然還能上傳新物件到 storage.objects';
  exception when insufficient_privilege then
    null; -- ok（RLS 違反，標準 42501，storage policy 沒有自訂碼可用，見 §5）
  end;

  reset role;
  raise notice 'ok：停權後 storage.objects 的 select／insert 皆被擋（M4 mutation 回歸保護）';
end;
$$;

rollback;

-- ---------------------------------------------------------------------------
-- 場景 13（R2，m3，M5 mutation 存活的回歸保護 ＋ m2）：families_select 的
-- created_by 分支——建立者已離開家庭（family_ids() 因此看不到它），此時唯一
-- 還看得到這個家庭的路徑就是 created_by 分支。merge-review R1 的 M5 mutation
-- （拿掉這個分支的 caller_is_active()）在補這個測試之前全綠存活；同一個場景
-- 順便釘住 m2（family_is_active(id)）。
-- ---------------------------------------------------------------------------
begin;

-- a1 是 A 家建立者兼唯一 owner；先把 a2 也升成 owner，a1 才能離開而不撞
-- enforce_family_has_owner（owner 不變量）。
update public.family_members set role = 'owner'
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';
delete from public.family_members
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000001';

do $$
declare
  n int;
begin
  -- 正面對照：a1 已離開，但仍是 created_by，未停權時這個分支應該讓他看到 1 列
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.families where id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 1 then
    raise exception 'FAIL：已離開家庭的建立者，未停權時應該仍能透過 created_by 分支看到 1 列，實際 %', n;
  end if;

  reset role;
end;
$$;

update public.profiles set suspended_at = now()
 where id = 'a0000000-0000-4000-8000-000000000001';

do $$
declare
  n int;
begin
  -- m1／M5：建立者本人被停權 → created_by 分支必須拒絕
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.families where id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：已離開家庭且被停權的建立者，仍透過 created_by 分支看到 % 列', n;
  end if;

  reset role;
  raise notice 'ok：created_by 分支對停權的建立者正確拒絕（M5 mutation 回歸保護）';
end;
$$;

update public.profiles set suspended_at = null
 where id = 'a0000000-0000-4000-8000-000000000001';
update public.families set suspended_at = now()
 where id = 'fa000000-0000-4000-8000-000000000001';

do $$
declare
  n int;
begin
  -- m2：建立者本人未停權，但家庭本身停權 → created_by 分支同樣必須拒絕
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.families where id = 'fa000000-0000-4000-8000-000000000001';
  if n <> 0 then
    raise exception 'FAIL：家庭停權後，未被個別停權的建立者仍透過 created_by 分支看到 % 列（m2）', n;
  end if;

  reset role;
  raise notice 'ok：created_by 分支對停權的家庭正確拒絕（m2 回歸保護）';
end;
$$;

rollback;
