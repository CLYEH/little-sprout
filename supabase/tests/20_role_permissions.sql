-- LS-6：角色權限（PLAN §3 的角色表 + §10-A 的成本防線）
--
-- §3：Owner 管理家庭與內容；Member 預設可上傳、可由 Owner 逐人關閉；Viewer 只能看與留言。
-- 這些規則寫在 RLS policy 裡，所以必須有測試，否則「policy 有寫」不等於「policy 有效」。

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- Viewer：只能看與留言
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fa000000-0000-4000-8000-000000000001',
            'fa000000-0000-4000-8000-000000000001/2026/08/viewer.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000003');
    raise exception 'FAIL：viewer 竟然可以上傳照片';
  exception when insufficient_privilege then
    raise notice 'ok：viewer 不能上傳照片 (42501)';
  end;

  -- 但留言可以（§3）
  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values ('fa000000-0000-4000-8000-000000000001', 'media',
          '3a000000-0000-4000-8000-000000000001',
          'a0000000-0000-4000-8000-000000000003', 'viewer 的留言');
  raise notice 'ok：viewer 可以留言';

  -- 也不能管理成員
  begin
    insert into public.family_members (family_id, user_id, role)
    values ('fa000000-0000-4000-8000-000000000001',
            'b0000000-0000-4000-8000-000000000002', 'member');
    raise exception 'FAIL：viewer 竟然可以把外人加進家庭';
  exception when insufficient_privilege then
    raise notice 'ok：viewer 不能新增家庭成員 (42501)';
  end;
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- Member：can_upload = true 可以上傳；Owner 關掉之後就不能
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
  values ('fa000000-0000-4000-8000-000000000001',
          'fa000000-0000-4000-8000-000000000001/2026/08/member.jpg',
          'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000002');
  raise notice 'ok：can_upload 的 member 可以上傳';

  -- uploaded_by 不能冒名（否則「誰上傳的」在稽核與檢舉時不可信）
  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fa000000-0000-4000-8000-000000000001',
            'fa000000-0000-4000-8000-000000000001/2026/08/spoof.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：member 可以冒用他人身分當 uploaded_by';
  exception when insufficient_privilege then
    raise notice 'ok：uploaded_by 必須是本人 (42501)';
  end;
end;
$$;
reset role;

update public.family_members set can_upload = false
 where family_id = 'fa000000-0000-4000-8000-000000000001'
   and user_id = 'a0000000-0000-4000-8000-000000000002';

set local role authenticated;
do $$
begin
  begin
    insert into public.media (family_id, storage_path, type, byte_size, width, height, uploaded_by)
    values ('fa000000-0000-4000-8000-000000000001',
            'fa000000-0000-4000-8000-000000000001/2026/08/member2.jpg',
            'photo', 1024, 100, 100, 'a0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：can_upload=false 的 member 還是上傳成功了';
  exception when insufficient_privilege then
    raise notice 'ok：can_upload=false 的 member 不能上傳 (42501)';
  end;

  -- 但仍然是 member，可以寫日記（can_upload 只管照片）
  insert into public.diaries (family_id, author_id, body)
  values ('fa000000-0000-4000-8000-000000000001',
          'a0000000-0000-4000-8000-000000000002', 'can_upload 關掉也還是能寫日記');
  raise notice 'ok：can_upload=false 的 member 仍可寫日記';
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- §10-A 成本防線：額度與用量不是使用者能改的欄位
-- （RLS 管不到欄位，靠 column-level grant；沒有這一關，「硬防線」一句 UPDATE 就沒了）
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  -- 家庭名稱是 owner 改得動的
  update public.families set name = '改過的 A 家'
   where id = 'fa000000-0000-4000-8000-000000000001';
  if not found then
    raise exception 'FAIL：owner 改不動自家家庭名稱';
  end if;
  raise notice 'ok：owner 可以改家庭名稱';

  begin
    update public.families set storage_quota_bytes = 1099511627776
     where id = 'fa000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：owner 竟然可以自己調高儲存額度（§10-A 的防線形同虛設）';
  exception when insufficient_privilege then
    raise notice 'ok：storage_quota_bytes 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.families set storage_used_bytes = 0
     where id = 'fa000000-0000-4000-8000-000000000001';
    raise exception 'FAIL：owner 竟然可以自己把用量歸零';
  exception when insufficient_privilege then
    raise notice 'ok：storage_used_bytes 無 UPDATE 權限 (42501)';
  end;

  -- feed_items 是 trigger 的地盤，連 grant 都沒給
  begin
    insert into public.feed_items (family_id, kind, ref_id, occurred_at)
    values ('fa000000-0000-4000-8000-000000000001', 'media', gen_random_uuid(), now());
    raise exception 'FAIL：使用者可以自己偽造時間軸項目';
  exception when insufficient_privilege then
    raise notice 'ok：feed_items 不開放寫入 (42501)';
  end;
end;
$$;
reset role;

rollback;
