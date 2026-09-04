-- LS-155（LS-24 拆票）— 使用者裁決 2026-09-04：刪帳號時該使用者上傳的 media 一併
-- 軟刪（取代 LS-143 當時「media 刻意不在 delete_my_account() 範圍」的舊決定），
-- 30 天後由 LS-153 的 purge_expired() 沿用既有硬刪＋Storage 入列路徑一併清除。
--
-- 這是 `create or replace function public.delete_my_account()`：
-- `supabase/migrations/20260903084231_delete_account.sql`（LS-143）已進正式站、
-- 依規約不可回頭改那支檔案本身，這裡用同一支函式簽名整支覆寫。**除了下方「新增」
-- 段落，情況 1／2／3 的既有邏輯與 R2 m1／m2 併發設計逐字不變**——這裡只是把整支
-- 函式重新貼一份出來，好讓 CREATE OR REPLACE 生效；審這支 migration 時請只關注
-- 「新增」段落，其餘是既有行為的原樣延續。
--
-- ---------------------------------------------------------------------------
-- 新增：情況 3 延伸——使用者所有仍存在的 media 一併軟刪
-- ---------------------------------------------------------------------------
-- 範圍：`public.media` 中 `uploaded_by = auth.uid()` 且 `deleted_at is null` 的列
-- 一律 `deleted_at = now()`（含相簿內與日記附帶的 media；`diary_media`／
-- `album_media` 連結列不動，靠 `media.deleted_at` 軟刪隱藏，讀取端既有的
-- `deleted_at is null` 過濾自然讓這些連結失效，不需要另外清連結列）。**不限定
-- family_id**：情況 1 已經在函式最前面整個拒絕（不會執行到這裡），情況 2
-- （唯一成員）的家庭已經在上面被 `DELETE FROM families` cascade 硬刪，這裡的
-- `deleted_at is null` 篩選對那些列自然是「找不到」（列已經不存在），不需要額外
-- 排除，一句不分家庭的 UPDATE 就同時涵蓋「情況 3 的每個家庭」，簡單且與這支函式
-- 一貫「不重複判斷同一件事」的風格一致。
--
-- 額度：不需要另外寫任何程式碼。`families.storage_used_bytes` 由既有的
-- `private.media_storage_sync()`（`20260822120100_triggers.sql`）AFTER UPDATE
-- 統計級 trigger 維護——這句 UPDATE 一旦執行，deleted_at 從 NULL 變成非 NULL 的
-- 那批列會被那支既有 trigger 自動偵測並立即扣減對應家庭的 storage_used_bytes，
-- 同 `docs/API.md` §6「families.storage_used_bytes **不會**在硬刪時再扣一次額度
-- ——軟刪的當下就已經被扣過」那段描述的既有機制，這裡只是第一次讓
-- `delete_my_account()` 也走到這條既有路徑。
--
-- 永久清除：不需要另外寫任何程式碼。LS-153 的 `private.purge_expired()` 已經對
-- `media.deleted_at` 超過 30 天的列做硬刪＋（透過 `private.media_storage_queue_sync()`
-- trigger）入列 `public.purge_storage_queue`，這支 migration 只需要把 `deleted_at`
-- 設成非 NULL，30 天後的清除路徑原封不動沿用。
--
-- **鎖序（為什麼放在「離開剩餘家庭」的 `DELETE FROM family_members` 之後，不是跟
-- 上面 `UPDATE diaries/albums/comments` 放一起）**——這是本票要求對齊的重點：
-- `private.media_storage_sync()` 的 AFTER UPDATE 統計級 trigger 會對受影響家庭的
-- `public.families` 列下一句 `UPDATE ... SET storage_used_bytes = ...`，這本身就是
-- 一個會在這張表上取隱含列鎖的動作（效果同 `FOR NO KEY UPDATE`，因為只改
-- `storage_used_bytes` 這個非鍵欄位）。`20260903115014_delete_account_edge_support.sql`
-- （LS-151）的檔頭已經記錄過 R2→R3 的教訓：`public.finalize_account_deletion()`
-- 一度把取鎖順序寫成「先鎖 `families`、再鎖 `family_members`」，與本 schema 唯一的
-- 權威防線 `private.enforce_family_has_owner()`（掛在 `family_members` 的 AFTER
-- STATEMENT，天生是「先讓 DML 自然鎖住 `family_members` 列、trigger 才鎖
-- `families`」的順序）相反，R2 review 雙連線實測出跨交易的 40P01 死鎖——兩個
-- session 各自持有對方在等的那把鎖，互相等待。
--
-- 若把這句 media 的 `UPDATE` 放在 `DELETE FROM family_members` **之前**（例如跟上面
-- 三句 `UPDATE diaries/albums/comments` 放一起），這個交易會先摸到 `families`（透過
-- media trigger）、後摸到 `family_members`（透過下面的 `DELETE`）——這正是「families
-- 先、family_members 後」，與 `enforce_family_has_owner()`／`finalize_account_deletion()`
-- 的既有順序相反，會重新打開同一類死鎖窗：若某個成員 U2 在同一個家庭的
-- `finalize_account_deletion()`（Edge Function 刪帳號流程的第一道防線）與這裡的
-- U1 幾乎同時執行，U1 可能先鎖住 `families`（media trigger）、U2 的
-- `finalize_account_deletion()` 先鎖住 `family_members`（含 U1 尚未被刪除的那一列，
-- 因為它會鎖住該 family 底下**全部**成員列）——U1 接著要 `DELETE FROM
-- family_members` 撞上 U2 持有的鎖、U2 接著要鎖 `families` 撞上 U1 持有的鎖，
-- 兩邊互等，40P01。
--
-- 改放在 `DELETE FROM family_members` **之後**就不會有這個問題，而且不只是「順序
-- 對了」，是「根本不會產生新的等待」：`DELETE FROM family_members WHERE user_id =
-- v_uid` 觸發的 `family_members_owner_guard_delete`（AFTER STATEMENT，見
-- `20260822120100_triggers.sql`）會對這次刪除影響到的**每一個**家庭（也就是情況 3
-- 的每個家庭，跟這裡 media UPDATE 會影響到的家庭集合完全相同——情況 1 已提早整個
-- 拒絕、情況 2 的家庭這時已經因為 cascade 而不存在）取 `FOR NO KEY UPDATE`，
-- `family_id` 遞增序。等這句 media 的 `UPDATE` 執行、`media_storage_sync()` trigger
-- 對這些**同一批**家庭列下 `UPDATE storage_used_bytes` 時，這個交易早已持有這些列
-- 的鎖（owner_guard 剛取得的）——同一個交易對自己已經持有的列鎖不會再等待，這裡
-- 只是重新確認一次已經拿到手的鎖，不會產生任何新的跨交易等待窗口。全交易內對
-- `families` 與 `family_members` 的取鎖順序因此維持「`family_members` 先、
-- `families` 後」，與既有 trigger 及 `finalize_account_deletion()` R3 版本一致。
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

  -- 情況 3：其餘家庭——自己的內容依既有 soft delete 策略處理，家庭不受影響。上面
  -- 情況 2 的 DELETE 若已經處理過某個家庭，這裡三句 UPDATE 的 family_id 子查詢
  -- 自然不會再包含它（成員列隨家庭一起 cascade 掉了，下面子查詢查不到）。
  update public.diaries d
     set deleted_at = now(), deleted_by = v_uid
   where d.author_id = v_uid
     and d.deleted_at is null
     and d.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  update public.albums a
     set deleted_at = now(), deleted_by = v_uid
   where a.created_by = v_uid
     and a.deleted_at is null
     and a.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  update public.comments c
     set deleted_at = now(), deleted_by = v_uid
   where c.author_id = v_uid
     and c.deleted_at is null
     and c.family_id in (
       select fm.family_id from public.family_members fm where fm.user_id = v_uid
     );

  -- 離開剩餘家庭：一句 DELETE 涵蓋呼叫者在情況 2 之外的每個家庭。這句話觸發的既有
  -- trigger（private.enforce_family_has_owner()）才是「家庭必須恆有 ≥1 owner」的
  -- 權威防線，同時也是本交易第一次對這批家庭的 public.families 列取鎖（FOR NO KEY
  -- UPDATE，family_id 遞增序）。
  delete from public.family_members where user_id = v_uid;

  -- 情況 3 延伸（LS-155 新增，見上方 migration 檔頭「鎖序」段落）：使用者所有仍
  -- 存在的 media（含相簿內與日記附帶）一併軟刪。刻意放在上面 DELETE
  -- family_members 之後——這個交易此刻已經因為 owner_guard trigger 持有這批家庭
  -- 的 families 列鎖，下面這句 UPDATE 觸發的 private.media_storage_sync()
  -- （既有 trigger，見 20260822120100_triggers.sql）對同一批家庭列做的
  -- storage_used_bytes 扣減只是重新確認已持有的鎖，不產生新的跨交易等待，額度
  -- 因此在這句話執行完就立即釋放，不需要另外的程式碼。
  update public.media m
     set deleted_at = now()
   where m.uploaded_by = v_uid
     and m.deleted_at is null;

  -- 情況 4：標記已請求刪除。auth.users 的實際刪除由另一支以 service_role 執行的
  -- 流程完成（另票，不在本 migration 範圍——見 20260903084231_delete_account.sql
  -- 檔頭「規格分歧與取捨 a)」）。
  update public.profiles set deletion_requested_at = now() where id = v_uid;
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
