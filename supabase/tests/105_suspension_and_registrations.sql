-- LS-179（LS-23 後端切片）— 使用者／家庭停權旗標＋註冊開關
--
-- 對應 migration 20260904212530_suspension_and_registrations.sql。沿用
-- 00_fixtures.sql 的固定家庭／使用者（A 家：owner a1／member a2／viewer a3；
-- B 家：owner b1／member b2；C 家＝效能測試家，owner c1）。
--
-- 每個場景各自 begin/rollback，互不污染 fixtures（比照本目錄既有慣例）。

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 場景 1：使用者停權 —— SELECT 全面拒絕，其他人不受影響
-- ---------------------------------------------------------------------------
begin;

update public.profiles set suspended_at = now(), suspended_reason = '測試用停權'
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

update public.profiles set suspended_at = now(), suspended_reason = '測試用停權'
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

update public.profiles set suspended_at = now(), suspended_reason = '測試用停權'
 where id = 'a0000000-0000-4000-8000-000000000002';
update public.profiles set suspended_at = null, suspended_reason = null
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

update public.families set suspended_at = now(), suspended_reason = '測試用家庭停權'
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

update public.profiles set suspended_at = now(), suspended_reason = '測試用停權'
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

update public.families set suspended_at = now(), suspended_reason = '測試用家庭停權'
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

  update public.profiles set suspended_at = now(), suspended_reason = '測試用停權'
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
