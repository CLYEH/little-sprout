-- LS-401 — delete_my_account()：情況 3 不再軟刪呼叫者建立的 albums
--
-- 來源：LS-394 QA 實走（i2）。A 刪帳號時，A 建立的相簿（裡面有 B 的 10 張照片）
-- 隨 A 軟刪，B 的相簿分頁變空、照片仍在時間軸——符合 docs/API.md §4 舊契約
-- （情況 3「自己的 diaries／albums／comments 依既有 soft delete 策略處理」），但
-- 不是使用者要的結果。使用者 2026-09-29 裁決（決策單 4o9SGXAE 第 6 題，
-- LS-394 i2 → c）：**相簿不隨作者刪、只軟刪作者自己的照片**——家庭相簿是共有物，
-- 作者離開不該帶走容器。
--
-- 改動（整支函式本體逐字複製自 20260904212530_suspension_and_registrations.sql
-- 第 8 段的目前定義，該檔 append-only 不可回頭改）——**只拿掉一句**：情況 3
-- 分支裡 `update public.albums … set deleted_at = now(), deleted_by = v_uid`。
-- 其餘一律不動：
--   - diaries／comments 的軟刪、DELETE family_members、情況 1 守門（LS050）、
--     情況 2（唯一成員整個家庭 cascade，albums 仍隨家庭一起硬刪）不變；
--   - media 逐家庭軟刪（LS-155）不變，album_media 連結列不動；
--   - 鎖序（family_members 先、families 後、family_id 遞增序）與語句順序不變：
--     被拿掉的是一句在兩把鎖之內、不取任何新鎖的 UPDATE，拿掉它只會少寫一張表，
--     不會改變任何與 LS-155 逐家庭處理、`delete_account_*` 併發場景相關的取鎖順序。
--     albums 上原本被這句 UPDATE 觸發的 private.feed_sync_albums() 等 trigger 也
--     就不再被這條路徑觸發，沒有新的鎖。
--
-- 規格分歧與取捨：
--   a) 相簿 vs 日記／留言為什麼處置不同：相簿是**多人容器**——B 可以往 A 建的
--      相簿裡放自己的照片（album_media 由任一 owner／member 寫入），容器的價值
--      屬於全家；日記與留言是**作者個人內容**，作者離開，內容隨之收回（與
--      LS-143 原契約、隱私政策「使用者的內容依請求刪除」一致）。media 仍軟刪，
--      因為照片是上傳者個人資料（LS-155），相簿只是把它們裝在一起。
--   b) 孤兒相簿（albums.created_by 不再是家庭成員）：`albums.created_by` 對
--      profiles 是 `on delete set null`（20260822120000_init_schema.sql:154）。
--      呼叫者離開家庭後 created_by 仍指向他（profile 列還在，直到 Edge Function
--      刪除 auth.users 才因 cascade 而 set null；若走 purge tombstone 路徑則指向
--      tombstone 列）。不論哪種，albums_update 的建立者分支
--      （created_by = auth.uid()）再也沒有人符合：**標題／封面（title／
--      cover_media_id）無人可直接 .update()**；owner 仍可用既有的
--      set_album_deleted（軟刪／還原）與 set_album_children，album_media 仍可由
--      任一 owner／member 增刪。本票**不新增**接手編輯路徑（要不要給 owner
--      接手編輯另議，見 handoff／docs/API.md §4）。
--   c) 不回填：先前因刪帳號而被軟刪的相簿不還原（正式站尚無真實使用者）。
--
-- 與 20260903084231／20260904070941／20260904212530 三檔關係：本檔是 CREATE OR
-- REPLACE，取代它們的定義；三檔頭部關於 albums 軟刪的敘述（尤其
-- 20260903084231 檔頭「範圍 3」）以本檔為準，不回頭改（migration-immutable）。

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_blocking jsonb;
  v_family_id uuid;
  v_solo_candidates uuid[];
begin
  if v_uid is null then
    raise exception '未登入，無法刪除帳號' using errcode = '42501';
  end if;

  -- R2（MAJOR-2）：見本檔第 8 段檔頭與 private.deletion_bypass_active() 的
  -- 函式註解。放在這裡（登入檢查之後、情況 1 唯讀查詢之前）：情況 1 是唯讀、
  -- 不取鎖、不觸發任何 trigger，這一行放在它前後對正確性沒有差別，選擇放在
  -- 最前面只是讓「這支函式從頭到尾都在豁免範圍內」一目了然。
  perform private.enforce_deletion_bypass();

  -- 情況 1：呼叫者是某家庭的唯一 owner、且家庭還有其他成員 → 一次列出全部這樣的
  -- 家庭並拒絕（不是找到第一個就報，使用者一次看到所有要處理的家庭）。唯讀查詢，
  -- 不取任何鎖，見上方「逐入口列表」前言。
  select jsonb_agg(
           jsonb_build_object('family_id', fm.family_id, 'family_name', f.name)
           order by f.name, fm.family_id
         )
    into v_blocking
    from public.family_members fm
    join public.families f on f.id = fm.family_id
   where fm.user_id = v_uid
     and fm.role = 'owner'
     and exists (
       select 1 from public.family_members other
        where other.family_id = fm.family_id and other.user_id <> v_uid
     )
     and not exists (
       select 1 from public.family_members co
        where co.family_id = fm.family_id and co.role = 'owner' and co.user_id <> v_uid
     );

  if v_blocking is not null then
    raise exception
      '你是家庭的唯一 owner，且家庭還有其他成員，請先把 owner 身份轉移給其他成員才能刪除帳號'
      using errcode = 'LS050', detail = v_blocking::text;
  end if;

  -- 情況 2 候選家庭（LS-143 R2 m2 既有的「兩段式」第一段：初始快照，鎖之前）：
  -- 呼叫者「現在」看起來是唯一成員的家庭。**這個集合本身刻意用取鎖前的快照**——
  -- 不是本函式的新設計，是 LS-143 從一開始就有的既有語意，R3 合併進單一迴圈時
  -- 原樣保留（見下方迴圈內「鎖內重新評估」如何使用這個集合，以及為什麼「只有
  -- 快照時就已經是候選的家庭」才有資格走 cascade 分支——反例見
  -- `delete_account_race_*.sql`：owner 2 呼叫當下 owner 1 還在，owner 2 的快照
  -- 不含這個家庭，即使 owner 2 鎖到的時候 owner 1 已經離開、家庭「看起來」唯一
  -- 成員了，owner 2 仍然只能走情況 3 的一般離開路徑、觸發既有 owner 不變量
  -- trigger 拿 LS001 重試——這是既有、刻意的行為，不是本次合併要修的東西）。
  select coalesce(array_agg(fm.family_id), '{}') into v_solo_candidates
    from public.family_members fm
   where fm.user_id = v_uid
     and not exists (
       select 1 from public.family_members other
        where other.family_id = fm.family_id and other.user_id <> v_uid
     );

  -- 情況 2＋3（R3 合併，見上方 migration 檔頭「修訂歷史」）：家庭來源＝「呼叫者
  -- 目前所屬的家庭」∪「呼叫者還有未軟刪 media 的家庭」，單一遞增序迴圈。
  for v_family_id in
    select fm.family_id from public.family_members fm where fm.user_id = v_uid
    union
    select distinct m.family_id from public.media m
     where m.uploaded_by = v_uid and m.deleted_at is null
    order by 1
  loop
    -- 先鎖住整個家庭的 family_members（不只是呼叫者自己那一列——這個家庭可能
    -- 呼叫者根本不是成員，鎖的是「這個家庭現有的全部成員」，比照
    -- finalize_account_deletion() 的既有寫法），再鎖 families（FOR UPDATE，理由
    -- 見上方檔頭）——同一個家庭內任何後續動作都排在這兩把鎖之後。
    perform 1 from public.family_members where family_id = v_family_id for update;
    perform 1 from public.families f where f.id = v_family_id for update;

    -- 鎖內用全新查詢重新判斷呼叫者現在是不是這個家庭的成員。
    if exists (
      select 1 from public.family_members fm2
       where fm2.family_id = v_family_id and fm2.user_id = v_uid
    ) then
      if v_family_id = any(v_solo_candidates) and not exists (
        select 1 from public.family_members other
         where other.family_id = v_family_id and other.user_id <> v_uid
      ) then
        -- 情況 2：取鎖前的快照就已經是候選（見上方），鎖內用全新查詢重新評估
        -- 仍然是唯一成員——LS-143 R2 m2「兩段式」的第二段。整個家庭連同底下
        -- 資料一併刪除（cascade：albums／diaries／media／album_media／
        -- diary_media／comments／reactions／invites／join_requests／
        -- content_reports／blocked_users／feed_items／family_members 全部隨之
        -- 消失）。
        delete from public.families f where f.id = v_family_id;
      else
        -- 情況 3：不是候選（一般成員，快照當下就不是唯一成員），或曾是候選但
        -- 鎖內重新評估已經不再是唯一成員（例如快照之後有人被 approve_join 加入
        -- ——LS-143 R2 m2 的既有保護，見
        -- `delete_account_vs_approve_join_*.sql`）——皆走一般路徑：自己的
        -- diaries／comments 依既有 soft delete 策略處理（**albums 不動**，見檔頭
        -- LS-401 段；自己上傳的 media 在下方迴圈尾端軟刪），然後離開家庭。家庭本身與其他成員的內容
        -- 完全不受影響。這句 DELETE 觸發的既有 trigger
        -- （private.enforce_family_has_owner()）是「家庭必須恆有 ≥1 owner」的
        -- 權威防線，會再對這個家庭的 families 列取鎖（FOR NO KEY UPDATE）——
        -- 此刻已經持有上面的 families FOR UPDATE 鎖，不會產生新的跨交易等待；
        -- 若這句 DELETE 讓家庭剩 0 位 owner（見 `delete_account_race_*.sql` 的
        -- 既有情境），trigger 會擋下並回 LS001、整個呼叫隨事務回滾，使用者
        -- 需要重試——這是既有、刻意的自我修復路徑，本次合併不改變它。
        update public.diaries d
           set deleted_at = now(), deleted_by = v_uid
         where d.author_id = v_uid and d.deleted_at is null and d.family_id = v_family_id;

        update public.comments c
           set deleted_at = now(), deleted_by = v_uid
         where c.author_id = v_uid and c.deleted_at is null and c.family_id = v_family_id;

        delete from public.family_members where family_id = v_family_id and user_id = v_uid;
      end if;
    end if;
    -- 呼叫者不是這個家庭的成員（已退出／被移除、只留有 media）：上面整個 if 是
    -- no-op，直接進下面的 media 軟刪。

    -- media 軟刪（不論上面走哪個分支）：這個家庭裡呼叫者上傳、尚未軟刪的 media
    -- 一併處理。若上面剛好把整個家庭 cascade 刪掉，這裡的 WHERE 對已經不存在的
    -- family_id 自然是 0 筆，不會出錯。觸發的 private.media_storage_sync()
    -- trigger 對這個家庭的 families 列取鎖，此刻已經持有上面的鎖，不會產生新的
    -- 跨交易等待。
    update public.media m
       set deleted_at = now()
     where m.uploaded_by = v_uid
       and m.deleted_at is null
       and m.family_id = v_family_id;
  end loop;

  -- 情況 4：標記已請求刪除。auth.users 的實際刪除由另一支以 service_role 執行的
  -- 流程完成（另票，不在本 migration 範圍——見 20260903084231_delete_account.sql
  -- 檔頭「規格分歧與取捨 a)」）。
  update public.profiles set deletion_requested_at = now() where id = v_uid;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
