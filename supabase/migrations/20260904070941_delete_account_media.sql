-- LS-155（LS-24 拆票）— 使用者裁決 2026-09-04：刪帳號時該使用者上傳的 media 一併
-- 軟刪（取代 LS-143 當時「media 刻意不在 delete_my_account() 範圍」的舊決定），
-- 30 天後由 LS-153 的 purge_expired() 沿用既有硬刪＋Storage 入列路徑一併清除。
--
-- 這是 `create or replace function public.delete_my_account()`：
-- `supabase/migrations/20260903084231_delete_account.sql`（LS-143）已進正式站、
-- 依規約不可回頭改那支檔案本身，這裡用同一支函式簽名整支覆寫。**情況 1 的既有
-- 邏輯逐字不變**；情況 2／3 因為要合併 media 處理與死鎖修法，R3 起已重寫成單一
-- 遞增序迴圈（見下方），對呼叫者而言的淨效果與 LS-143 原版逐字相同，只是實作換成
-- 逐家庭執行。
--
-- ---------------------------------------------------------------------------
-- 修訂歷史（R1→R2→R3 三輪，每輪都是「鎖序證明少算一個入口」被抓到——完整記錄，
-- 供之後改這支函式的人對照，不要重蹈）
-- ---------------------------------------------------------------------------
--
-- R1（merge-review R1 `b68e89d3` M1，實測重現 40P01）：R1 版本在情況 3 的
-- 「離開剩餘家庭」DELETE 之後加一句不分家庭的 `UPDATE media SET deleted_at =
-- now() WHERE uploaded_by = v_uid AND deleted_at IS NULL`，檔頭宣稱「media
-- UPDATE 觸碰到的家庭集合＝情況 3（呼叫者仍是成員）的家庭集合，鎖序天然對齊」
-- ——這句話不成立：呼叫者可能已經退出或被移除某個家庭、但那個家庭裡還留著他
-- 上傳的 media（`family_members_delete` policy 允許自行退出／被移除，退出時
-- media 不會被清掉，是既有、有文件的正常狀態）。對這種「已非成員的家庭」，
-- `DELETE FROM family_members WHERE user_id = v_uid` 完全不會產生任何列、
-- `enforce_family_has_owner()` 也不會鎖它，那句 media UPDATE 因此是本交易對這個
-- 家庭**唯一一次**取鎖，且是「families 先、family_members 後」——與
-- `finalize_account_deletion()` 既有鎖序相反。reviewer 用三連線實測重現 40P01。
--
-- R2 第一次嘗試（同一輪 review 裡自己的常駐迴歸測試抓到，還沒送審）：把 media
-- 改成「先用一個獨立迴圈把牽涉到的每個家庭的 family_members 都鎖住（遞增序），
-- 再做 media UPDATE」，放在「離開剩餘家庭」DELETE **之後**。同一組三連線時序
-- **仍然**死鎖：DELETE 只碰得到「呼叫者目前仍是成員」的家庭，這一步先於新迴圈
-- 執行；若呼叫者同時在「已退出但留有 media」的家庭（family_id 比較小）也有
-- 照片，交易真實的觸碰順序是「family_members(A) → families(A)（先，經 DELETE／
-- owner_guard）→ family_members(X) → families(X)（後，經新迴圈）」——家庭 A 先、
-- 家庭 X 後，跟 `finalize_account_deletion()` 對同一組家庭「X 先、A 後」的順序
-- **交叉相反**，古典 AB-BA 死鎖形狀：光是「每個家庭內 family_members 先於
-- families」不夠，**跨家庭的相對順序也必須全域一致**。
--
-- R2 送審版本：把情況 3 的三句 soft-delete UPDATE、離開家庭 DELETE、media 軟刪
-- 全部合併進單一遞增序迴圈——家庭來源＝「呼叫者目前所屬的家庭」∪「呼叫者還有
-- 未軟刪 media 的家庭」，每個家庭先鎖整個 family_members 再動作。**但情況 2
-- （唯一成員家庭）當時仍是獨立的、迴圈外的邏輯**（先一個迴圈鎖住候選家庭的
-- `families FOR UPDATE`、迴圈結束後才一次 `delete from families where id =
-- any(v_solo_ids)`，cascade 才碰 family_members）——這正是 merge-review R2
-- （`9779da79`）抓到的 **R2-M1**：情況 2 對每個候選家庭是「families 先、
-- family_members 後」（cascade 硬刪才碰成員列），跟情況 3 合併迴圈、
-- `finalize_account_deletion()` 的「family_members 先」相反，而且情況 2／3
-- 是兩個各自遞增序、但涵蓋不同家庭子集的迴圈——合起來不是全域遞增序，正是 R2
-- 送審版本自己檔頭寫下的那個反面案例形狀。reviewer 用 N1（人工撐窗）／N2（U1
-- 自己的背景上傳佔另一家庭的 `families` 列鎖——真實行為，不需要人工鎖）兩種方式
-- 各重現一次 40P01，對照組（函式換回 LS-143 版）不死鎖。
--
-- **R3（本次）最終修法**：情況 2 也併進**同一個**遞增序迴圈——不再有任何獨立於
-- 這個迴圈之外、會碰 `families`／`family_members` 的邏輯（情況 1 是唯讀守門查詢，
-- 不取鎖，不算）。家庭來源不變（「呼叫者目前所屬的家庭」∪「呼叫者還有未軟刪
-- media 的家庭」——情況 2 的候選家庭本來就是「呼叫者目前所屬的家庭」的子集，
-- 不需要第三個來源），每個家庭先鎖整個 `family_members`、再鎖 `families`
-- （`FOR UPDATE`，理由見下）。
--
-- **LS-143 R2 m2「兩段式」語意原樣保留，這是 reviewer 明確要求「必須原樣保留」
-- 的部分，這裡說清楚怎麼保留的**：候選集合（`v_solo_candidates`）仍然是**取鎖
-- 前**的快照——呼叫者「當下」看起來是唯一成員的家庭。迴圈內鎖到某個家庭之後，
-- **只有這個家庭當初就在候選快照裡**，才會用鎖內的全新查詢重新驗證是否仍是
-- 唯一成員、通過才 cascade 刪除；候選但重新驗證失敗（例如鎖之前到鎖之後這段
-- 期間被 `approve_join()` 加了新成員）、或者根本不是候選（快照當下就已經不是
-- 唯一成員）——兩種情況一律走情況 3 的一般路徑（軟刪內容＋離開），**不會**因為
-- 鎖到的當下「碰巧」變成唯一成員就臨時升級成 cascade。這條界線很重要：
-- `supabase/tests/concurrency/delete_account_race_*.sql`（LS-143 既有測試）驗的
-- 正是「owner 2 呼叫當下 owner 1 還在，owner 2 的快照不含這個家庭；即使 owner 2
-- 鎖到時 owner 1 已經離開、家庭表面上唯一成員了，owner 2 仍然只能走一般離開
-- 路徑、觸發既有 owner 不變量 trigger 拿 `LS001` 需要重試」——如果迴圈內對
-- **每個**家庭都無條件重新判斷唯一成員（不管快照當時是不是候選），這個既有測試
-- 會變成 owner 2 直接 cascade 刪除成功，行為改變、測試炸掉（本票 R3 開發過程中
-- 先寫過這個更簡單的版本，`91_`／`delete_account_race_*` 全綠但這個測試紅，
-- 逼出這裡的候選快照保留設計）。除了「候選判斷用快照、不是鎖內即時判斷」這一點
-- 外，安全性保證與 LS-143 完全相同：先取鎖、再用鎖後的新快照重新驗證「仍是候選
-- 且仍是唯一成員」、驗證通過才真正執行 DELETE；差別只是把「先收集全部候選、
-- 迴圈結束後批次 DELETE」改成「每個家庭鎖到之後立刻判斷、立刻 DELETE」，家庭
-- 之間彼此獨立（各自的資料只屬於自己，cascade 不會互相影響），這個重排本身不
-- 改變任何安全性論證。非候選家庭走情況 3 之後，一律做這個家庭的 media 軟刪
-- （不論走了哪個分支）。
--
-- **為什麼是 `FOR UPDATE`、不是 `FOR NO KEY UPDATE`**：迴圈內任何一個家庭都可能
-- 落入「唯一成員」分支而需要 `DELETE FROM families`——DELETE 終究需要 FOR
-- UPDATE 等級的列鎖，且這把鎖需要跟子表 INSERT（背景上傳、`approve_join()`）的
-- FK 檢查取的 `FOR KEY SHARE` 互斥，才能正確擋住「候選判斷用的是取鎖前的舊
-- 快照」這個競態窗——同 LS-143 情況 2 m1／m2 的既有理由，`FOR NO KEY UPDATE`
-- 鎖不住 `FOR KEY SHARE`。
--
-- **逐入口列表（coordinator 要求：兩輪的根因都是「證明少算一個入口」，這次列出
-- 全部會取得 `families` 或 `family_members` 鎖、且同一交易內可能同時碰到兩張表
-- 的入口，逐一說明為什麼現在是同一套「family_members 先、families 後、跨家庭
-- family_id 遞增序」紀律，`grep -n "for update\|for no key update\|for key
-- share" supabase/migrations/*.sql` 核對過沒有遺漏）**：
--   1. 本函式（`delete_my_account()`）——上述合併迴圈，逐一符合。
--   2. `public.finalize_account_deletion()`（`20260903115014_delete_account_edge_support.sql`
--      ＋本票 `20260904080802_finalize_account_deletion_media.sql`）——自己的
--      逐家庭迴圈，同樣「family_members FOR UPDATE 先、families FOR UPDATE
--      後」、`family_id` 遞增序，家庭來源＝「p_user 現有家庭」∪「p_user 還有
--      未軟刪 media 的家庭」。
--   3. `private.enforce_family_has_owner()`（owner 不變量 trigger，
--      `20260822120100_triggers.sql`）——掛在 `family_members` 的 AFTER
--      STATEMENT（DELETE／UPDATE），觸發它的 DML（本函式的
--      `delete from family_members`、`finalize_account_deletion()` 同名操作、
--      或使用者直接離開家庭／owner 轉移角色的 client 端 UPDATE／DELETE）天生先
--      鎖住自己正在改的 `family_members` 列，trigger 本身才對受影響的
--      **每個**家庭（`distinct family_id from removed_members order by 1`）鎖
--      `families FOR NO KEY UPDATE`——順序與遞增序皆與上述一致，這顆 trigger
--      本身就是「family_members 先、families 後、遞增序」這套紀律最早的來源
--      （LS-6／LS-15，先於 LS-143／LS-151／LS-155 存在）。
--   4. `public.approve_join()`（`20260823010000_join_approval.sql`）——`INSERT
--      INTO family_members` 本身只在新插入的那一列取鎖（新列，不與任何既有列的
--      `FOR UPDATE` 衝突），FK 參照完整性檢查對 `families` 取的是 `FOR KEY
--      SHARE`（弱鎖，只與 `FOR UPDATE`／`FOR NO KEY UPDATE` 衝突，`FOR KEY
--      SHARE` 之間互不衝突）——這支函式**不會**在同一交易內先鎖住任何既有
--      `family_members` 列、也不會反過來被上述迴圈「先 family_members 後
--      families」的順序卡住形成循環：它對 `families` 的（弱）鎖與對
--      `family_members` 的（新列）鎖之間沒有跨交易的相依關係，只會被上述迴圈的
--      `families FOR UPDATE` 正常阻塞、不構成循環等待——這正是
--      `supabase/tests/concurrency/delete_account_vs_approve_join_*.sql`
--      （LS-143 R2 m2）與本票 `race_case3`／N2 場景要驗的事，兩者皆綠。
-- 這四者是全 repo 唯一會在同一支函式／trigger 內同時取得 `families` 與
-- `family_members` 鎖的地方（純粹只碰其中一張表、從不在同一交易內碰到另一張的
-- 呼叫端——例如 `families_update` policy 的 owner 改名——不構成跨表交叉，不列入）。
-- 常駐迴歸測試：`supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql`
-- （R2-M1 的三連線時序）與 `delete_account_case2_vs_media_*.sql`（本輪新增，
-- reviewer N2 的「唯一成員家庭＋他人遺留 media＋背景上傳佔另一家庭鎖」時序）。
-- ---------------------------------------------------------------------------
--
-- ---------------------------------------------------------------------------
-- 情況 2＋3（合併版）——唯一成員家庭 cascade 刪除／其餘家庭軟刪內容＋離開／media
-- 軟刪，單一遞增序迴圈
-- ---------------------------------------------------------------------------
-- media 範圍：`public.media` 中 `uploaded_by = auth.uid()` 且 `deleted_at is null`
-- 的列一律 `deleted_at = now()`（含相簿內與日記附帶的 media；`diary_media`／
-- `album_media` 連結列不動，靠 `media.deleted_at` 軟刪隱藏——讀取端配合
-- `20260904080921_media_select_hide_deleted.sql` 的 `media_select` RLS 收斂）。
-- **不限定「呼叫者目前是不是這個家庭的成員」**：情況 1 已經在函式最前面整個
-- 拒絕（不會執行到這裡），這裡直接從 `media` 表本身反查「呼叫者還有哪些未軟刪
-- 的 media、分佈在哪些家庭」，天然只涵蓋還有列可清的家庭。若某個家庭在本次迴圈
-- 走到唯一成員分支被整個 cascade 刪除，這裡的 media 軟刪對那個 family_id 自然
-- 找不到列（硬刪已經在同一次迭代內先發生），不會出錯也不會重複處理。
--
-- 額度：不需要另外寫任何程式碼。`families.storage_used_bytes` 由既有的
-- `private.media_storage_sync()`（`20260822120100_triggers.sql`）AFTER UPDATE
-- 統計級 trigger 維護——下面的 UPDATE 一旦執行，deleted_at 從 NULL 變成非 NULL 的
-- 那批列會被那支既有 trigger 自動偵測並立即扣減對應家庭的 storage_used_bytes，
-- 同 `docs/API.md` §6「families.storage_used_bytes **不會**在硬刪時再扣一次額度
-- ——軟刪的當下就已經被扣過」那段描述的既有機制，這裡只是第一次讓
-- `delete_my_account()` 也走到這條既有路徑。
--
-- 永久清除：不需要另外寫任何程式碼。LS-153 的 `private.purge_expired()` 已經對
-- `media.deleted_at` 超過 30 天的列做硬刪＋（透過 `private.media_storage_queue_sync()`
-- trigger）入列 `public.purge_storage_queue`，這支 migration 只需要把 `deleted_at`
-- 設成非 NULL，30 天後的清除路徑原封不動沿用。
-- ---------------------------------------------------------------------------

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
        -- `delete_account_vs_approve_join_*.sql`）——皆走一般路徑：自己的內容
        -- 依既有 soft delete 策略處理，然後離開家庭。家庭本身與其他成員的內容
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

        update public.albums a
           set deleted_at = now(), deleted_by = v_uid
         where a.created_by = v_uid and a.deleted_at is null and a.family_id = v_family_id;

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
