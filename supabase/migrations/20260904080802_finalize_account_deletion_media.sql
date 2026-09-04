-- LS-155 R2（merge-review R1 `b68e89d3` m2，實測重現：`LS-155-e5b-*.sql`／
-- `LS-155-driver.out`「A：在飛上傳」段落）— finalize_account_deletion() 重跑一次
-- media 軟刪，補上 delete_my_account() 交易提交窗口內的在飛上傳孤兒缺口。
--
-- 這是 `create or replace function public.finalize_account_deletion(uuid)`：
-- `supabase/migrations/20260903115014_delete_account_edge_support.sql`（LS-151）
-- 已進正式站、依規約不可回頭改那支檔案本身，這裡用同一支函式簽名整支覆寫。**除了
-- 下方「新增」段落，既有邏輯逐字不變**——審這支 migration 時請只關注「新增」段落。
--
-- ---------------------------------------------------------------------------
-- 問題（reviewer E5b，雙連線實測）：`delete_my_account()`（本交易）尚未提交時，
-- 呼叫者自己的另一個 session（例如 iOS 背景上傳佇列的重試）送出 `INSERT INTO
-- media`——`media_deletion_guard`（LS051，`private.enforce_account_not_deletion_requested()`）
-- 是快照讀，看不到本交易尚未提交的 `deletion_requested_at`，於是放行；這句 INSERT
-- 的 AFTER STATEMENT trigger（`media_storage_sync`）接著卡在本交易持有的
-- `families` 列鎖，直到本交易提交才真正寫入。結果：`delete_my_account()` 那句
-- `20260904070941_delete_account_media.sql` 的 media UPDATE 用的是**取鎖之前**的
-- 快照（`deleted_at is null` 篩選在那個時間點還看不到這張正在插入的列），這張
-- 在飛上傳因此以 `deleted_at = NULL` 留下——`deletion_requested_at` 已標記，帳號
-- 進入刪除流程，但這張照片從此不會再被任何路徑重新檢查。實測輸出：舊列
-- `still_active=f`（已軟刪）、在飛列 `still_active=t`（仍是 NULL）。之後 Edge
-- Function 刪除 `auth.users` 時，`media.uploaded_by` 因為 `on delete set null`
-- 被清空——這張照片從此不在任何清除集合內（`purge_expired()` 的判準是
-- `deleted_at`，不是 `uploaded_by`），永久留在家庭裡且無人可歸屬，也違背隱私政策
-- 「30 天內永久清除」的承諾。
--
-- 為什麼窗口小但不能忽略：reviewer 也實測過另一種時序（上傳先取得 families
-- 鎖）——這種情況 `delete_my_account()` 會被 owner_guard 卡住，之後的 media
-- UPDATE 用新快照抓到那一列並正確軟刪，沒有問題。窗口只存在於「`delete_my_account()`
-- 已持有 families 鎖、且新上傳的 LS051 guard 已經讀完快照（尚未寫入）」這一小段
-- ——機率低，但 iOS 端上傳是背景佇列＋重試（不是「使用者不可能同時上傳」），且
-- 一旦真的踩到，後果是永久孤兒，不是可重試的錯誤。
--
-- 修法（reviewer 建議，與本函式既有設計完全同構）：`finalize_account_deletion()`
-- 是 Edge Function 在呼叫 `service_role` 執行 `delete from auth.users` 之前的
-- 「第一道防線：重跑一次資料面清理」——它執行的時間點 `deletion_requested_at`
-- 必然已經提交可見（這是 Edge Function 呼叫它的前提，函式開頭那句
-- exists 檢查已經在驗證這件事），LS051 guard 之後不會再放行任何新上傳，這一步
-- 之後不會再有新的孤兒產生。這裡補上同一種 media 軟刪，用與
-- `20260904070941_delete_account_media.sql` R2 相同的邏輯（不限定「p_user 目前
-- 是不是這個家庭的成員」，直接從 `media` 表反查）。
--
-- 鎖序：**合併進本函式既有的逐家庭迴圈**（不是另開一個獨立迴圈），理由是避免
-- 「兩個獨立的遞增序迴圈、各自處理不同的家庭子集」在極端情況下對整體交易的取鎖
-- 順序失去單一遞增保證（見 `20260904070941_delete_account_media.sql` 檔頭「R2」
-- 段落的證明——那段證明要求「T1 對共享家庭集合 S 的第一個動作永遠是
-- family_members(min(S))」，若本函式自己內部拆成兩個迴圈、迭代對象是
-- family_members 集合與 media 集合的**不對稱聯集**，S 的最小元素未必落在第一個
-- 迴圈踩到的第一步，證明的前提就不成立）。改法：迴圈的迭代來源從「p_user 目前所屬
-- 的家庭」改成「p_user 目前所屬的家庭」∪「p_user 還有未軟刪 media 的家庭」（後者
-- 正常情況下應為空集合——delete_my_account() 已經處理過，這裡只接住 m2 那種
-- 提交窗口內的殘留），單一遞增序（`family_id`）處理；原本「p_user 是不是這個家庭
-- 成員」的判斷從迴圈起手的 `continue` 改寫成正向 `if exists(...) then` 包住既有
-- 升格／刪除邏輯，讓「p_user 已經不是成員、只是留有孤兒 media」的家庭也能進到迴圈
-- 尾端的 media 軟刪，不會被提早 `continue` 跳過。families 的顯式 `for update`
-- （既有寫法，比照 delete_my_account() 情況 2 的既有理由：與子表 INSERT 的 FK
-- 檢查取的 FOR KEY SHARE 互斥）對純 media 孤兒的家庭保留不拿掉——不是這個修法
-- 嚴格必要（LS051 guard 此時已經生效，擋得住新上傳），但維持與既有程式碼同一種
-- 防禦風格，不為了省一行鎖而分裂寫法。
-- ---------------------------------------------------------------------------

create or replace function public.finalize_account_deletion(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family_id uuid;
  v_is_owner boolean;
  v_promote_user uuid;
begin
  if not exists (
    select 1 from public.profiles
     where id = p_user and deletion_requested_at is not null
  ) then
    raise exception
      'finalize_account_deletion 只能用於已呼叫 delete_my_account() 標記
      deletion_requested_at 的使用者（防止誤呼叫刪除健康帳號的家庭關係）'
      using errcode = '42501';
  end if;

  -- 1. 刪除 p_user 尚未處理的加入申請。join_requests.applicant_id 對 profiles 是
  --    on delete cascade（20260823010000_join_approval.sql:83），所以 auth.users
  --    真正被刪除時這些列本來就會消失——這裡提早清是為了讓 EF 在後面步驟意外中途
  --    失敗時，這筆申請也已經不在，不會留下一筆申請人已標記刪除、卻還沒被 GoTrue
  --    真正移除的過渡態殘留。
  delete from public.join_requests where applicant_id = p_user and status = 'pending';

  -- 2.（R2 合併：家庭列表＝原本「p_user 目前所屬的家庭」∪「p_user 還有未軟刪
  --    media 的家庭」，見上方「鎖序」段落）逐一處理每個家庭（鎖序：family_members
  --    先、families 後，對齊既有 trigger；family_id 遞增序）。
  for v_family_id in
    select fm.family_id from public.family_members fm where fm.user_id = p_user
    union
    select distinct m.family_id from public.media m
     where m.uploaded_by = p_user and m.deleted_at is null
    order by 1
  loop
    perform 1 from public.family_members fm2 where fm2.family_id = v_family_id for update;
    perform 1 from public.families f where f.id = v_family_id for update;

    -- 取鎖過程中 p_user 理論上不會被別的路徑移除（這是目前對 family_members 唯一
    -- 會這樣做的清理路徑，且此刻已持有鎖），但仍保守處理，避免下面誤判出多餘的
    -- 升格／刪除。R2：從「不存在就 continue（跳過整個家庭）」改成正向
    -- `if exists then`——這個家庭若只是純 media 孤兒（p_user 從一開始就不是成員，
    -- 例如已經退出很久的舊家庭），不該連下面的 media 軟刪也一起跳過。
    if exists (
      select 1 from public.family_members fm3
       where fm3.family_id = v_family_id and fm3.user_id = p_user
    ) then
      select (fm4.role = 'owner') into v_is_owner
        from public.family_members fm4
       where fm4.family_id = v_family_id and fm4.user_id = p_user;

      if v_is_owner and not exists (
        select 1 from public.family_members fm5
         where fm5.family_id = v_family_id and fm5.role = 'owner' and fm5.user_id <> p_user
      ) then
        -- 唯一 owner：找家庭裡最早加入的其他成員升為 owner，再刪除 p_user。
        select fm6.user_id into v_promote_user
          from public.family_members fm6
         where fm6.family_id = v_family_id and fm6.user_id <> p_user
         order by fm6.created_at, fm6.user_id
         limit 1;

        if v_promote_user is not null then
          update public.family_members set role = 'owner'
           where family_id = v_family_id and user_id = v_promote_user;

          delete from public.family_members
           where family_id = v_family_id and user_id = p_user;
        else
          -- 沒有其他成員：整個家庭連同底下資料一併刪除（cascade，語意同
          -- delete_my_account() 的「唯一成員」情況）。
          delete from public.families where id = v_family_id;
        end if;
      else
        -- 不是唯一 owner（一般成員／viewer，或家庭還有其他共同 owner）：直接刪除
        -- p_user 這一列，不影響家庭與其他成員。
        delete from public.family_members
         where family_id = v_family_id and user_id = p_user;
      end if;
    end if;

    -- 3.（R2 新增，m2）media 軟刪：不論上面那個 if 是否成立，只要這個家庭還有
    --    p_user 上傳、尚未軟刪的 media 就一併處理——正常路徑下這裡通常是 0 筆
    --    （delete_my_account() 已經處理過），只有 m2 描述的提交窗口內在飛上傳才
    --    會落到這裡。families.storage_used_bytes 的扣減由既有
    --    private.media_storage_sync() trigger 自動處理，同
    --    20260904070941_delete_account_media.sql 的既有機制，不需要另外的程式碼。
    --    若上面那句 `delete from public.families` 剛好把這個家庭整個刪掉
    --    （cascade），這裡的 UPDATE 對已經不存在的 family_id 自然是 0 筆，
    --    不會出錯（media 列本身也隨 cascade 一起消失了）。
    update public.media m
       set deleted_at = now()
     where m.uploaded_by = p_user
       and m.deleted_at is null
       and m.family_id = v_family_id;
  end loop;
end;
$$;

revoke all on function public.finalize_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.finalize_account_deletion(uuid) to service_role;

comment on function public.finalize_account_deletion(uuid) is
  'LS-151 R2（merge-review R1 B1／M1）：Edge Function delete-account 在呼叫
  service_role 執行 `delete from auth.users` 之前，先以 service_role 重跑一次
  資料面清理——不依賴過渡期擋寫（LS051）完全沒有漏洞，是讓「刪除一定成功」的
  第一道、真正的防線。只能用於 deletion_requested_at 已標記的使用者，只有
  service_role 能執行。R3（merge-review R2 N1）：取鎖順序（family_members 先、
  families 後）對齊既有 private.enforce_family_has_owner()，避免與同家庭併發的
  成員異動互為死鎖。LS-155 R2（merge-review R1 m2）：同一個逐家庭迴圈額外重跑一次
  media 軟刪（family 列表擴充為「p_user 現有家庭」∪「p_user 還有未軟刪 media 的
  家庭」），接住 delete_my_account() 交易提交窗口內在飛上傳留下的孤兒列，見
  20260904080802_finalize_account_deletion_media.sql 檔頭。';
