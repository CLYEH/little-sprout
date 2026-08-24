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

  -- 但留言可以（§3）。LS-58：comments 的 INSERT 收斂成 RPC-only（create_comment），
  -- 直接 .insert() 已被 revoke，這裡改呼叫 RPC。
  perform public.create_comment('fa000000-0000-4000-8000-000000000001', 'media',
    '3a000000-0000-4000-8000-000000000001', 'viewer 的留言');
  raise notice 'ok：viewer 可以留言（create_comment RPC）';

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

  -- 但仍然是 member，可以寫日記（can_upload 只管照片）。LS-48 之後 diaries 的寫入
  -- 唯一路徑是 create_diary_entry（RPC），不再是直接 INSERT——見
  -- supabase/tests/85_diaries_timeline.sql 對這條收斂本身的完整驗收。
  perform public.create_diary_entry(
    'fa000000-0000-4000-8000-000000000001', null, 'can_upload 關掉也還是能寫日記', null);
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

-- ---------------------------------------------------------------------------
-- §10-A 成本防線的 INSERT 面：建立家庭時不能自帶額度
--
-- 只擋 UPDATE 是擋不住的——任何登入者都能建立家庭（§9-C5），如果 INSERT 是全欄位權限，
-- 第一步就可以把 storage_quota_bytes 設成 1 TiB，後面的 UPDATE 防線再嚴也沒有意義。
-- 同一段順便驗 §9-C5 的建立家庭路徑本身：`insert ... returning` 必須成功
-- （supabase-swift 走 PostgREST 的 return=representation，RETURNING 會套用 SELECT policy）。
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_me uuid := 'c0000000-0000-4000-8000-000000000001';
  v_id uuid;
  v_quota bigint;
  v_used bigint;
  v_owners int;
begin
  begin
    insert into public.families (name, created_by, storage_quota_bytes)
    values ('自帶 1 TiB 的家', v_me, 1099511627776);
    raise exception 'FAIL：建立家庭時可以自帶 storage_quota_bytes（§10-A 防線在 INSERT 面被繞過）';
  exception when insufficient_privilege then
    raise notice 'ok：INSERT 不能指定 storage_quota_bytes (42501)';
  end;

  begin
    insert into public.families (name, created_by, storage_used_bytes)
    values ('自帶用量的家', v_me, 0);
    raise exception 'FAIL：建立家庭時可以自帶 storage_used_bytes';
  exception when insufficient_privilege then
    raise notice 'ok：INSERT 不能指定 storage_used_bytes (42501)';
  end;

  -- 正向：只給 name / created_by 必須成功，而且 RETURNING 拿得回列。
  -- RETURNING 會套用 SELECT policy，而成員列是 AFTER INSERT trigger 才產生的——
  -- SELECT policy 只認 family_members 的話，這一句必噴 42501。
  begin
    insert into public.families (name, created_by)
    values ('新手自己開的家', v_me)
    returning id into v_id;
  exception when insufficient_privilege then
    raise exception
      'FAIL：authenticated 無法 insert ... returning 建立家庭 —— PostgREST 的 return=representation 路徑壞掉（§9-C5）：%',
      sqlerrm;
  end;
  if v_id is null then
    raise exception 'FAIL：insert ... returning 沒有拿到新家庭的 id';
  end if;
  raise notice 'ok：authenticated 可以 insert ... returning 建立家庭（§9-C5 的起點）';

  select storage_quota_bytes, storage_used_bytes into v_quota, v_used
    from public.families where id = v_id;
  if v_quota <> 5368709120 or v_used <> 0 then
    raise exception 'FAIL：新家庭沒有拿到預設額度（quota=% used=%）', v_quota, v_used;
  end if;
  raise notice 'ok：新家庭拿到預設額度 5 GiB、用量 0';

  -- 建立者必須立刻是 owner，否則新家庭會鎖死自己（§9-C5）
  select count(*) into v_owners from public.family_members
   where family_id = v_id and user_id = v_me and role = 'owner';
  if v_owners <> 1 then
    raise exception 'FAIL：建立者沒有成為 owner';
  end if;
  raise notice 'ok：建立者立刻成為 owner';
end;
$$;
reset role;
rollback;

-- ---------------------------------------------------------------------------
-- media 的 UPDATE 面：可改的欄位只有那四欄
--
-- byte_size 是 storage_used_bytes 的來源。若上傳者能改自己照片的 byte_size，
-- 一句 UPDATE 就能把整個家庭的用量歸零，§10-A 的額度防線等於不存在。
-- storage_path / family_id / uploaded_by 同理：檔案位置、歸屬與稽核來源都不該由客戶端改寫。
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_media uuid := '3a000000-0000-4000-8000-000000000001';
  v_n int;
begin
  begin
    update public.media set byte_size = 0 where id = v_media;
    raise exception 'FAIL：上傳者可以把 byte_size 改成 0（一句 UPDATE 就能釋放整家的額度）';
  exception when insufficient_privilege then
    raise notice 'ok：byte_size 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.media set storage_path = 'fa000000-0000-4000-8000-000000000001/hijack.jpg'
     where id = v_media;
    raise exception 'FAIL：可以改 storage_path（檔案位置與 bucket 內容會對不上）';
  exception when insufficient_privilege then
    raise notice 'ok：storage_path 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.media set family_id = 'fb000000-0000-4000-8000-000000000001' where id = v_media;
    raise exception 'FAIL：可以把自己的照片改掛到別的家庭';
  exception when insufficient_privilege then
    raise notice 'ok：family_id 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.media set uploaded_by = 'a0000000-0000-4000-8000-000000000002' where id = v_media;
    raise exception 'FAIL：可以改 uploaded_by（稽核與檢舉時「誰上傳的」就不可信）';
  exception when insufficient_privilege then
    raise notice 'ok：uploaded_by 無 UPDATE 權限 (42501)';
  end;

  -- 正向對照：soft delete 這條主要路徑仍然要通（否則就是改成「全部擋光」的假通過）
  update public.media set deleted_at = now() where id = v_media;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 改不動 deleted_at（soft delete 路徑壞掉），影響 % 列', v_n;
  end if;
  update public.media set taken_at = now() - interval '5 days' where id = v_media;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'FAIL：owner 改不動 taken_at（EXIF 補正路徑壞掉）';
  end if;
  raise notice 'ok：deleted_at／taken_at 仍可更新（soft delete 與 EXIF 補正不受影響）';
end;
$$;
reset role;
rollback;

-- ---------------------------------------------------------------------------
-- content_reports：owner 只能把檢舉標記成已處理
--
-- §10-B：被檢舉的很可能就是 owner 本人。若 owner 能改 reason／reporter_id，
-- 或能自己把檢舉設成 dismissed，UGC 檢舉機制形同不存在。
-- ---------------------------------------------------------------------------
begin;
select set_config('request.jwt.claims',
  '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_report uuid := '8a000000-0000-4000-8000-000000000001';
  v_n int;
  v_status public.report_status;
begin
  -- 竄改的兩句刻意連 status = 'resolved' 一起設：這樣 RLS 的 WITH CHECK 會放行，
  -- 唯一還能擋下它的就是 column-level grant。否則這兩條斷言會因為 WITH CHECK 而假通過，
  -- 把 grant 改回全欄位也測不出來。
  begin
    update public.content_reports set reason = '沒事了', status = 'resolved' where id = v_report;
    raise exception 'FAIL：owner 可以竄改檢舉理由';
  exception when insufficient_privilege then
    raise notice 'ok：reason 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.content_reports
       set reporter_id = 'a0000000-0000-4000-8000-000000000001', status = 'resolved'
     where id = v_report;
    raise exception 'FAIL：owner 可以竄改檢舉人';
  exception when insufficient_privilege then
    raise notice 'ok：reporter_id 無 UPDATE 權限 (42501)';
  end;

  begin
    update public.content_reports set status = 'dismissed' where id = v_report;
    raise exception 'FAIL：owner 可以自己把檢舉駁回（dismissed 應保留給平台方）';
  exception when insufficient_privilege then
    raise notice 'ok：owner 不能把檢舉設成 dismissed (42501)';
  end;

  update public.content_reports set status = 'resolved' where id = v_report;
  get diagnostics v_n = row_count;
  select status into v_status from public.content_reports where id = v_report;
  if v_n <> 1 or v_status <> 'resolved' then
    raise exception 'FAIL：owner 標記檢舉為 resolved 失敗（影響 % 列，status=%）', v_n, v_status;
  end if;
  raise notice 'ok：owner 可以把檢舉標記成 resolved';
end;
$$;
reset role;
rollback;
