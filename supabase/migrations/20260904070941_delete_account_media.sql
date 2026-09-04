-- LS-155（LS-24 拆票）— 使用者裁決 2026-09-04：刪帳號時該使用者上傳的 media 一併
-- 軟刪（取代 LS-143 當時「media 刻意不在 delete_my_account() 範圍」的舊決定），
-- 30 天後由 LS-153 的 purge_expired() 沿用既有硬刪＋Storage 入列路徑一併清除。
--
-- 這是 `create or replace function public.delete_my_account()`：
-- `supabase/migrations/20260903084231_delete_account.sql`（LS-143）已進正式站、
-- 依規約不可回頭改那支檔案本身，這裡用同一支函式簽名整支覆寫。**情況 1／2 的既有
-- 邏輯與 R2 m1／m2 併發設計逐字不變**；情況 3 因為要合併 media 處理而重寫成單一
-- 遞增序迴圈（見下方），淨效果與 LS-143 原版相同，只是拆成逐家庭執行。
--
-- ---------------------------------------------------------------------------
-- R2（merge-review R1 `b68e89d3` M1，實測重現 40P01；`LS-155-driver.out`／
-- `LS-155-e3-*.sql` 為 reviewer 實測證據）：R1 版本「families 集合完全相同、只是
-- 重新確認已持有的鎖」這句話有一個前提沒有成立——它假設 media UPDATE 觸碰到的
-- 家庭集合＝情況 3（呼叫者仍是成員）的家庭集合。**這個假設是錯的**：呼叫者可能
-- 早已退出或被移除某個家庭、但那個家庭裡還留著他上傳的 media（`family_members_delete`
-- policy 明文允許「owner 移除成員／任何人自行退出」，退出時 media 不會被清掉，見
-- `docs/API.md:195`／`20260822120200_rls_policies.sql:166`——這是既有、有文件的正常
-- 狀態，不是邊界案例）。對這種「已非成員的家庭」，本交易的 `DELETE FROM
-- family_members WHERE user_id = v_uid` 根本不會產生任何列（那裡沒有他的成員列可
-- 刪），`enforce_family_has_owner()` AFTER STATEMENT trigger 自然也不會被觸發、不會
-- 鎖它——R1 版本的 media UPDATE 因此是本交易**第一次、也是唯一一次**對這個家庭的
-- `families` 列取鎖，而且發生在本交易已經持有其他家庭的 `families`／`family_members`
-- 鎖之後，是徹頭徹尾的「families 先、family_members 後」，reviewer 用三連線
-- （U1 已退出但留有 media 的家庭 X、U1 仍是成員的家庭 A、正在跑
-- `finalize_account_deletion()` 的另一位成員 U3）實測重現 40P01。裁定採 reviewer
-- 建議的修法 (a)：不縮小範圍（票文使用者裁決是「該使用者上傳的照片全部刪」，縮到
-- 「仍是成員的家庭」會讓「已退出但留有照片」的家庭永遠刪不到，違背這個裁決）。
--
-- **R2 一次修正裡踩到的第二個坑（自己的常駐迴歸測試抓到，記錄下來）**：第一版 R2
-- 修法只是把「情況 3 原本的三句 UPDATE ＋ 離開家庭 DELETE」維持不變，media 改成
-- 「先用一個獨立迴圈把 media 牽涉到的每個家庭的 family_members 都鎖住（遞增序），
-- 再做 media UPDATE」，放在 DELETE family_members **之後**。這個版本用
-- `supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql`（把 reviewer
-- 的三連線時序寫成常駐案例）自我驗證時，**仍然重現了 40P01**：原因是「離開剩餘
-- 家庭」的 `DELETE FROM family_members WHERE user_id = v_uid` 只碰得到「呼叫者
-- 目前仍是成員」的家庭（範例裡的家庭 A），這一步**先於**新的 media 迴圈執行——
-- 若呼叫者同時在「已退出但留有 media」的家庭（範例裡的家庭 X，family_id 比 A
-- 小）也有照片，交易的真實觸碰順序會是「family_members(A) → families(A)（先，
-- 透過 DELETE／owner_guard）→ family_members(X) → families(X)（後，透過 media
-- 迴圈)」——這是家庭 A 先、家庭 X 後，跟 `finalize_account_deletion()` 對同一組
-- 家庭「X 先、A 後」（純粹遞增序）的順序**交叉相反**（A-X vs X-A 的古典
-- AB-BA 死鎖形狀），跟「families 先、family_members 後」是同一類問題的不同變體：
-- 光是「每個家庭內 family_members 先於 families」還不夠，**跨家庭的相對順序也
-- 必須全域一致**（見下方函式本體「情況 3」合併迴圈的證明）。
--
-- **最終修法**：把「情況 3」的三句 soft-delete UPDATE、「離開家庭」的 DELETE、與
-- 「media 軟刪」全部合併進**同一個**遞增序迴圈——家庭來源＝「呼叫者目前所屬的
-- 家庭」∪「呼叫者還有未軟刪 media 的家庭」，`family_id` 遞增序，每個家庭**先**
-- 鎖住整個 `family_members`（不只是呼叫者自己那一列，比照
-- `finalize_account_deletion()` 的既有寫法）、**再**依序做「若仍是成員則軟刪內容
-- ＋離開」「軟刪這個家庭裡的 media」——同一個家庭的 `family_members` 永遠先於
-- `families`（`families` 是透過離開家庭的 DELETE 觸發的 `enforce_family_has_owner()`
-- 或 media UPDATE 觸發的 `media_storage_sync()` 才被摸到，兩者都發生在同一次迴圈
-- 疊代、家庭鎖已經拿到之後），且**只有一個迴圈**——不會再出現「兩個各自遞增序、
-- 但涵蓋不同家庭子集的迴圈，合起來卻不是全域遞增序」這種交叉。可證明不會死鎖：
-- 兩個交易若都需要碰到同一組家庭集合 S，兩者對 S 的第一個動作永遠是
-- `family_members(min(S))`（單一互斥資源），先搶到的一方會暢通無阻跑完 S 的
-- 其餘部分（輸家此時手上一無所有，擋不住贏家），不會出現循環等待——前提是雙方
-- 對 S 的處理都遵守同一個遞增序、且不會在跨到下一個家庭之前就去摸更後面家庭的
-- `families`，這正是「合併成一個迴圈」要保證的事。常駐迴歸測試：
-- `supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql`（重現
-- reviewer 的三連線時序，這一版修後不死鎖；上面兩個錯誤版本〔R1、以及本 R2 檔頭
-- 這段描述的「獨立迴圈」中間版本〕跑同一組時序都會 40P01，已於本票 handoff 一次性
-- 驗證，不留在常駐測試裡）。
--
-- ---------------------------------------------------------------------------
-- 情況 3（合併版）——自己的內容依既有 soft delete 策略處理＋離開家庭＋media 軟刪
-- ---------------------------------------------------------------------------
-- media 範圍：`public.media` 中 `uploaded_by = auth.uid()` 且 `deleted_at is null`
-- 的列一律 `deleted_at = now()`（含相簿內與日記附帶的 media；`diary_media`／
-- `album_media` 連結列不動，靠 `media.deleted_at` 軟刪隱藏——讀取端配合
-- `20260904080921_media_select_hide_deleted.sql` 的 `media_select` RLS 收斂）。
-- **不限定 family_id、也不限定「呼叫者目前是不是成員」**：情況 1 已經在函式最
-- 前面整個拒絕（不會執行到這裡），情況 2（唯一成員）的家庭已經在上面被
-- `DELETE FROM families` cascade 硬刪，這裡直接從 `media` 表本身反查「呼叫者還有
-- 哪些未軟刪的 media、分佈在哪些家庭」，天然只涵蓋還有列可清的家庭——情況 2 的
-- 家庭因為列已經不存在，不會出現在這個反查結果裡，不需要額外排除。這個做法同時
-- 涵蓋「情況 3（呼叫者仍是成員）」與「呼叫者已退出／被移除、但留有 media」兩種
-- 家庭，滿足使用者裁決「該使用者上傳的照片全部刪」，不縮小範圍。
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
  v_solo_ids uuid[] := '{}';
begin
  if v_uid is null then
    raise exception '未登入，無法刪除帳號' using errcode = '42501';
  end if;

  -- 情況 1：呼叫者是某家庭的唯一 owner、且家庭還有其他成員 → 一次列出全部這樣的
  -- 家庭並拒絕（不是找到第一個就報，使用者一次看到所有要處理的家庭）。
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

  -- 情況 2（R2 修正 m2，見 20260903084231_delete_account.sql 檔頭「併發設計」）：
  -- 呼叫者是唯一成員的家庭 → 整個家庭連同資料一併刪除（cascade）。通過上面的守門
  -- 之後，這裡判斷到的「唯一成員」家庭不可能與情況 1 重疊。**兩段式**：先逐一鎖住
  -- 候選家庭（family_id 遞增序，避免多個候選家庭之間的取鎖順序不一致）、鎖內用
  -- 全新查詢重新評估「唯一成員」，通過的才會真正進到最後一句 DELETE 的清單。
  for v_family_id in
    select fm.family_id from public.family_members fm
     where fm.user_id = v_uid
       and not exists (
         select 1 from public.family_members other
          where other.family_id = fm.family_id and other.user_id <> v_uid
       )
     order by fm.family_id
  loop
    perform 1 from public.families f where f.id = v_family_id for update;

    if not exists (
      select 1 from public.family_members other
       where other.family_id = v_family_id and other.user_id <> v_uid
    ) then
      v_solo_ids := array_append(v_solo_ids, v_family_id);
    end if;
  end loop;

  delete from public.families f where f.id = any(v_solo_ids);

  -- 情況 3（合併版，見上方 migration 檔頭）：家庭來源＝「呼叫者目前所屬的家庭」
  -- ∪「呼叫者還有未軟刪 media 的家庭」，單一遞增序迴圈。上面情況 2 已經處理過的
  -- 家庭這裡不會出現（family_members／media 皆已隨 cascade 消失，兩個子查詢都
  -- 查不到）。
  for v_family_id in
    select fm.family_id from public.family_members fm where fm.user_id = v_uid
    union
    select distinct m.family_id from public.media m
     where m.uploaded_by = v_uid and m.deleted_at is null
    order by 1
  loop
    -- 先鎖住整個家庭的 family_members（不只是呼叫者自己那一列——這個家庭可能
    -- 呼叫者根本不是成員，鎖的是「這個家庭現有的全部成員」，比照
    -- finalize_account_deletion() 的既有寫法），家庭內任何後續動作（離開家庭的
    -- DELETE、media UPDATE 觸發的 families 列鎖）都排在這把鎖之後——見上方
    -- migration 檔頭的死鎖證明。
    perform 1 from public.family_members where family_id = v_family_id for update;

    -- 若呼叫者仍是這個家庭的成員：自己的內容依既有 soft delete 策略處理，然後
    -- 離開家庭。這句 DELETE 觸發的既有 trigger（private.enforce_family_has_owner()）
    -- 是「家庭必須恆有 ≥1 owner」的權威防線，也會對這個家庭的 families 列取鎖
    -- （FOR NO KEY UPDATE）——此刻已經持有上面的 family_members 鎖，不會產生新的
    -- 跨交易等待。若呼叫者不是這個家庭的成員（已退出／被移除、只留有 media）：
    -- 這個 if 整段是 no-op，跳到下面的 media 軟刪。
    if exists (
      select 1 from public.family_members fm2
       where fm2.family_id = v_family_id and fm2.user_id = v_uid
    ) then
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

    -- media 軟刪（不論上面那個 if 是否成立）：這個家庭裡呼叫者上傳、尚未軟刪的
    -- media 一併處理。觸發的 private.media_storage_sync() trigger 對這個家庭的
    -- families 列取鎖，此刻已經持有上面的 family_members 鎖，不會產生新的跨交易
    -- 等待——見上方 migration 檔頭的死鎖證明。
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
