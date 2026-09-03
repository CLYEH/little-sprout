-- LS-149（LS-23 後端切片）——report_content／block_user／unblock_user／
-- remove_content_as_owner／get_family_quota 五支 RPC，＋封鎖過濾（時間軸／留言／相簿）。
--
-- 效能回歸（get_family_timeline／list_comments 加封鎖過濾後 buffers 是否失控）已經在
-- 50_rls_plan_no_percall_subquery.sql 覆蓋（該檔案原有的 get_family_timeline／
-- list_comments 效能段落現在天然涵蓋「v_has_blocks=false」這條路徑，見該 migration
-- 對 get_family_timeline 的說明）；本檔案只驗功能正確性，不重複量 buffers。
--
-- 沿用 00_fixtures.sql 既有的封鎖關係（不新增 fixture 列，直接借用）：
--   - A 家 owner（a1）已封鎖 A 家 viewer（a3）；A 家唯一一則留言（6a...001）正是 a3 發的。
--   - B 家 owner（b1）已封鎖 B 家 member（b2）；B 家唯一一則留言（6b...001）正是 b2 發的。
--   - content_reports 8a...001：a2 對留言 6a...001（作者 a3）送出的 pending 檢舉。
-- 這組既有資料剛好對齊 LS-149 要測的情境，省去重複造 fixture。

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. report_content：去重
-- ===========================================================================
begin;
do $$
declare
  v_id1 uuid;
  v_id2 uuid;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
  set local role authenticated;

  -- a3（viewer）檢舉 A 家相簿 4a...001（owner a1 建立的）——全新目標，之前沒人檢舉過。
  select public.report_content(
    'fa000000-0000-4000-8000-000000000001', 'album',
    '4a000000-0000-4000-8000-000000000001', '不喜歡這張'
  ) into v_id1;

  if v_id1 is null then
    raise exception 'FAIL：report_content 沒有回傳 id';
  end if;

  select count(*) into v_n from public.content_reports
   where target_type = 'album' and target_id = '4a000000-0000-4000-8000-000000000001'
     and reporter_id = 'a0000000-0000-4000-8000-000000000003' and status = 'pending';
  if v_n <> 1 then
    raise exception 'FAIL：report_content 沒有正確新增一筆 pending 報告（實際 % 筆）', v_n;
  end if;

  -- 同一人對同一目標再檢舉一次：必須去重，回傳同一個 id，不新增第二筆。
  select public.report_content(
    'fa000000-0000-4000-8000-000000000001', 'album',
    '4a000000-0000-4000-8000-000000000001', '還是不喜歡'
  ) into v_id2;

  if v_id2 is distinct from v_id1 then
    raise exception 'FAIL：重複檢舉沒有回傳既有的 id（v_id1=%，v_id2=%）', v_id1, v_id2;
  end if;

  select count(*) into v_n from public.content_reports
   where target_type = 'album' and target_id = '4a000000-0000-4000-8000-000000000001'
     and reporter_id = 'a0000000-0000-4000-8000-000000000003';
  if v_n <> 1 then
    raise exception 'FAIL 去重：重複檢舉多新增了列（實際 % 筆，mutation test：拿掉 partial unique index／ON CONFLICT 這裡會紅）', v_n;
  end if;

  raise notice 'ok：report_content 去重（同一人同一目標的 pending 報告只有一筆，重複呼叫回傳既有 id）';
end;
$$;
reset role;
rollback;

-- 既有 fixture 的重複檢舉：a2 再次檢舉 6a...001（已經在 00_fixtures.sql 裡對它送過一筆
-- pending 報告，id=8a000000...001），必須回傳那個既有 id，不新增列。
begin;
do $$
declare
  v_id uuid;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  select public.report_content(
    'fa000000-0000-4000-8000-000000000001', 'comment',
    '6a000000-0000-4000-8000-000000000001', '重複檢舉同一則留言'
  ) into v_id;

  if v_id <> '8a000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'FAIL：對既有 pending 報告重複檢舉，沒有回傳 fixture 既有的 id（實際 %）', v_id;
  end if;

  select count(*) into v_n from public.content_reports
   where target_type = 'comment' and target_id = '6a000000-0000-4000-8000-000000000001'
     and reporter_id = 'a0000000-0000-4000-8000-000000000002';
  if v_n <> 1 then
    raise exception 'FAIL：對 fixture 既有報告重複檢舉多新增了列（實際 % 筆）', v_n;
  end if;

  raise notice 'ok：report_content 對 fixture 既有 pending 報告去重成功';
end;
$$;
reset role;
rollback;

-- 跨家庭目標（LS026）：a2（A 家成員）用 A 家的 p_family_id 檢舉 B 家的相簿。
begin;
do $$
declare
  v_sqlstate text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.report_content(
      'fa000000-0000-4000-8000-000000000001', 'album',
      '4b000000-0000-4000-8000-000000000001', '這是別人家的相簿'
    );
    raise exception 'FAIL：跨家庭檢舉目標沒有被擋下';
  exception when sqlstate 'LS026' then
    raise notice 'ok：跨家庭檢舉目標被擋下（LS026）';
  end;
end;
$$;
reset role;
rollback;

-- 非該家庭成員：c0（效能測試帳號，不屬於 A 家）檢舉 A 家內容。
begin;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.report_content(
      'fa000000-0000-4000-8000-000000000001', 'album',
      '4a000000-0000-4000-8000-000000000001', '我根本不在這個家'
    );
    raise exception 'FAIL：非該家庭成員的檢舉沒有被擋下';
  exception when insufficient_privilege then
    raise notice 'ok：非該家庭成員的檢舉被擋下 (42501)';
  end;
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 2. block_user／unblock_user：冪等、自我封鎖、非成員
-- ===========================================================================
begin;
do $$
declare
  v_n int;
begin
  -- a2（A 家 member，00_fixtures.sql 裡沒有封鎖過任何人）封鎖 a3。
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  perform public.block_user('fa000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000003');

  select count(*) into v_n from public.blocked_users
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and blocker_id = 'a0000000-0000-4000-8000-000000000002'
     and blocked_id = 'a0000000-0000-4000-8000-000000000003';
  if v_n <> 1 then
    raise exception 'FAIL：block_user 沒有正確新增封鎖列（實際 % 筆）', v_n;
  end if;

  -- 重複封鎖同一人：冪等，不噴 23505，仍然只有一筆。
  perform public.block_user('fa000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000003');

  select count(*) into v_n from public.blocked_users
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and blocker_id = 'a0000000-0000-4000-8000-000000000002'
     and blocked_id = 'a0000000-0000-4000-8000-000000000003';
  if v_n <> 1 then
    raise exception 'FAIL：重複 block_user 沒有維持冪等（實際 % 筆）', v_n;
  end if;
  raise notice 'ok：block_user 新增與重複呼叫皆冪等';

  -- 解除封鎖：列被刪除。
  perform public.unblock_user('fa000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000003');
  select count(*) into v_n from public.blocked_users
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and blocker_id = 'a0000000-0000-4000-8000-000000000002'
     and blocked_id = 'a0000000-0000-4000-8000-000000000003';
  if v_n <> 0 then
    raise exception 'FAIL：unblock_user 沒有移除封鎖列（實際 % 筆）', v_n;
  end if;

  -- 對不存在的封鎖關係再次解除：冪等，不報錯。
  perform public.unblock_user('fa000000-0000-4000-8000-000000000001',
    'a0000000-0000-4000-8000-000000000003');
  raise notice 'ok：unblock_user 移除與重複呼叫皆冪等';
end;
$$;
reset role;
rollback;

-- 自我封鎖：既有 CHECK 約束擋下（23514），不是本票新開的碼。
begin;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.block_user('fa000000-0000-4000-8000-000000000001',
      'a0000000-0000-4000-8000-000000000002');
    raise exception 'FAIL：自我封鎖沒有被擋下';
  exception when check_violation then
    raise notice 'ok：自我封鎖被既有 CHECK 約束擋下 (23514 blocked_users_not_self)';
  end;
end;
$$;
reset role;
rollback;

-- 非該家庭成員：c0 對 A 家呼叫 block_user。
begin;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"c0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.block_user('fa000000-0000-4000-8000-000000000001',
      'a0000000-0000-4000-8000-000000000003');
    raise exception 'FAIL：非該家庭成員的 block_user 沒有被擋下';
  exception when insufficient_privilege then
    raise notice 'ok：非該家庭成員的 block_user 被擋下 (42501)';
  end;
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 3. remove_content_as_owner：owner 移除四種內容＋相關檢舉一併 resolved
-- ===========================================================================

-- comment：移除 6a...001（作者 a3）── fixture 裡剛好有一筆對它的 pending 檢舉
-- （8a...001，reporter a2），驗證移除後一併轉 resolved。
begin;
do $$
declare
  v_deleted_at timestamptz;
  v_status public.report_status;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform public.remove_content_as_owner('comment', '6a000000-0000-4000-8000-000000000001');

  -- 驗證改回 postgres 身分讀（繞過 RLS）：a1 已經封鎖了這則留言的作者 a3
  -- （00_fixtures.sql 既有關係），本票新增的 comments_select 封鎖過濾會讓 a1 直接
  -- 身分查這則留言變成 0 列——這是封鎖過濾正確生效的副作用，不是驗證應該撞到的東西，
  -- 驗證改用不受封鎖過濾影響的身分讀，纯粹確認底層資料真的被改了。
  reset role;

  select deleted_at into v_deleted_at from public.comments
   where id = '6a000000-0000-4000-8000-000000000001';
  if v_deleted_at is null then
    raise exception 'FAIL：remove_content_as_owner 沒有把留言軟刪';
  end if;

  select status into v_status from public.content_reports
   where id = '8a000000-0000-4000-8000-000000000001';
  if v_status <> 'resolved' then
    raise exception 'FAIL：移除內容後，相關檢舉沒有一併標記 resolved（實際 %）', v_status;
  end if;

  raise notice 'ok：remove_content_as_owner 移除留言並把相關檢舉標記 resolved';
end;
$$;
reset role;
rollback;

-- album／diary／media：owner 移除自家內容（不需要是別人建立的——這支只驗「是不是
-- owner」，不驗「是不是內容作者」）。
begin;
do $$
declare
  v_deleted_at timestamptz;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  perform public.remove_content_as_owner('album', '4a000000-0000-4000-8000-000000000001');
  select deleted_at into v_deleted_at from public.albums
   where id = '4a000000-0000-4000-8000-000000000001';
  if v_deleted_at is null then
    raise exception 'FAIL：remove_content_as_owner 沒有把相簿軟刪';
  end if;

  perform public.remove_content_as_owner('diary', '5a000000-0000-4000-8000-000000000001');
  select deleted_at into v_deleted_at from public.diaries
   where id = '5a000000-0000-4000-8000-000000000001';
  if v_deleted_at is null then
    raise exception 'FAIL：remove_content_as_owner 沒有把日記軟刪';
  end if;

  perform public.remove_content_as_owner('media', '3a000000-0000-4000-8000-000000000001');
  select deleted_at into v_deleted_at from public.media
   where id = '3a000000-0000-4000-8000-000000000001';
  if v_deleted_at is null then
    raise exception 'FAIL：remove_content_as_owner 沒有把照片軟刪';
  end if;

  raise notice 'ok：remove_content_as_owner 對 album／diary／media 三種內容皆正確軟刪';
end;
$$;
reset role;
rollback;

-- 非 owner 不能移除他人內容。
begin;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.remove_content_as_owner('comment', '6a000000-0000-4000-8000-000000000001');
    raise exception 'FAIL：非 owner 的 member 可以移除他人內容';
  exception when insufficient_privilege then
    raise notice 'ok：非 owner 的 member 不能移除他人內容 (42501)';
  end;
end;
$$;
reset role;
rollback;

-- 內容不存在：統一回 42501（不區分「不存在」與「不是 owner」，見 API.md §4）。
begin;
do $$
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  begin
    perform public.remove_content_as_owner('album', '4a000000-0000-4000-8000-00000000ffff');
    raise exception 'FAIL：移除不存在的內容沒有被擋下';
  exception when insufficient_privilege then
    raise notice 'ok：移除不存在的內容被擋下 (42501)';
  end;
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 4. get_family_quota
-- ===========================================================================
begin;
do $$
declare
  v_used bigint;
  v_quota bigint;
  v_n int;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  select storage_used_bytes, storage_quota_bytes into v_used, v_quota
    from public.get_family_quota('fa000000-0000-4000-8000-000000000001');
  if v_quota is null or v_quota <= 0 then
    raise exception 'FAIL：get_family_quota 沒有回傳合理的 storage_quota_bytes（實際 %）', v_quota;
  end if;
  if v_used is null or v_used < 0 then
    raise exception 'FAIL：get_family_quota 沒有回傳合理的 storage_used_bytes（實際 %）', v_used;
  end if;
  raise notice 'ok：get_family_quota 回傳 used=%／quota=%', v_used, v_quota;

  -- 非成員查別家額度：0 列（同 get_family_timeline 的既有裁量，不報錯）。
  select count(*) into v_n from public.get_family_quota('fb000000-0000-4000-8000-000000000001');
  if v_n <> 0 then
    raise exception 'FAIL：A 家 owner 查得到 B 家的額度（policy 外洩）';
  end if;
  raise notice 'ok：get_family_quota 對非自己所屬的家庭回傳 0 列';
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 5. 封鎖過濾：時間軸／留言／相簿三處各一案
--
-- 留言：直接借用既有 fixture（A 家 owner a1 已封鎖 A 家 viewer a3；A 家唯一一則留言
-- 6a...001 正是 a3 發的）——不需要新增資料。
--
-- 時間軸／相簿：a3 是 viewer，PLAN §3 viewer 不能建立相簿／日記／照片，既有 fixture
-- 裡沒有 a3 authored 的內容可用；改用 B 家（b1 封鎖 b2，b2 是 member，可以建立內容）。
-- 這裡在交易內插入一筆「b2 建立的相簿」（postgres 身分，繞過 RLS，同其他測試檔既有
-- fixture 準備慣例），驗證 b1（封鎖者）看不到、b2 自己（非封鎖者視角）看得到，交易結束
-- rollback，不留殘料。
-- ===========================================================================

-- 5a. 留言
begin;
do $$
declare
  v_n int;
begin
  -- a1（封鎖 a3）：list_comments 與直接 .from("comments") 都不該看到 a3 的留言。
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  select count(*) into v_n from public.list_comments(
    'fa000000-0000-4000-8000-000000000001', 'media',
    '3a000000-0000-4000-8000-000000000001'
  );
  if v_n <> 0 then
    raise exception 'FAIL 封鎖過濾（留言／list_comments）：owner 封鎖了留言作者，list_comments 卻回傳 % 筆（mutation test：拿掉 list_comments 裡的 NOT EXISTS 這裡會紅）', v_n;
  end if;

  select count(*) into v_n from public.comments
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and target_type = 'media' and target_id = '3a000000-0000-4000-8000-000000000001';
  if v_n <> 0 then
    raise exception 'FAIL 封鎖過濾（留言／直接 SELECT）：owner 封鎖了留言作者，comments_select 卻回傳 % 筆（mutation test：拿掉 comments_select 的 NOT EXISTS 這裡會紅）', v_n;
  end if;

  -- a2（沒有封鎖任何人）：同一則留言必須看得到——正向對照，證明不是整條 policy／RPC 壞掉。
  perform set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

  select count(*) into v_n from public.list_comments(
    'fa000000-0000-4000-8000-000000000001', 'media',
    '3a000000-0000-4000-8000-000000000001'
  );
  if v_n <> 1 then
    raise exception 'FAIL 正向對照（留言／list_comments）：非封鎖者查不到留言（實際 % 筆）', v_n;
  end if;

  select count(*) into v_n from public.comments
   where family_id = 'fa000000-0000-4000-8000-000000000001'
     and target_type = 'media' and target_id = '3a000000-0000-4000-8000-000000000001';
  if v_n <> 1 then
    raise exception 'FAIL 正向對照（留言／直接 SELECT）：非封鎖者查不到留言（實際 % 筆）', v_n;
  end if;

  raise notice 'ok：封鎖過濾（留言）——封鎖者看不到、非封鎖者看得到（list_comments 與直接 SELECT 皆驗證）';
end;
$$;
reset role;
rollback;

-- 5b／5c. 時間軸與相簿（共用同一筆 b2 建立的測試相簿）
begin;
do $$
declare
  v_album_id uuid := 'ab000000-0000-4000-8000-000000000001';
  v_n int;
begin
  -- postgres 身分插入（繞過 RLS），同其他測試檔既有 fixture 準備慣例。
  insert into public.albums (id, family_id, title, created_by)
  values (v_album_id, 'fb000000-0000-4000-8000-000000000001',
          '封鎖過濾測試相簿', 'b0000000-0000-4000-8000-000000000002');

  -- b1（封鎖 b2）：時間軸與相簿都不該看到這本相簿。
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  set local role authenticated;

  select count(*) into v_n from public.get_family_timeline(
    'fb000000-0000-4000-8000-000000000001'
  ) where kind = 'album' and ref_id = v_album_id;
  if v_n <> 0 then
    raise exception 'FAIL 封鎖過濾（時間軸）：owner 封鎖了建立者，get_family_timeline 卻回傳這本相簿（mutation test：拿掉 v_has_blocks 分支的 NOT EXISTS 這裡會紅）';
  end if;

  select count(*) into v_n from public.albums where id = v_album_id;
  if v_n <> 0 then
    raise exception 'FAIL 封鎖過濾（相簿）：owner 封鎖了建立者，albums_select 卻回傳這本相簿（mutation test：拿掉 albums_select 的 NOT EXISTS 這裡會紅）';
  end if;

  -- b2（相簿建立者本人，沒有封鎖任何人）：時間軸與相簿都看得到自己建立的這本相簿。
  perform set_config('request.jwt.claims',
    '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

  select count(*) into v_n from public.get_family_timeline(
    'fb000000-0000-4000-8000-000000000001'
  ) where kind = 'album' and ref_id = v_album_id;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照（時間軸）：非封鎖者查不到這本相簿（實際 % 筆）', v_n;
  end if;

  select count(*) into v_n from public.albums where id = v_album_id;
  if v_n <> 1 then
    raise exception 'FAIL 正向對照（相簿）：非封鎖者查不到這本相簿（實際 % 筆）', v_n;
  end if;

  raise notice 'ok：封鎖過濾（時間軸／相簿）——封鎖者看不到、非封鎖者（建立者本人）看得到';
end;
$$;
reset role;
rollback;

-- ===========================================================================
-- 6. content_reports／blocked_users 的 status／RLS column grant 已有 20_role_permissions.sql
--    覆蓋（owner 只能改 resolved、不能竄改 reason／reporter_id），跨家庭隔離已有
--    10_cross_family_isolation.sql 通掃覆蓋（含本票新增的兩張表），這裡不重複。
-- ===========================================================================
