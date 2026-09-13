-- LS-255（LS-250 後端先行）— growth_records（身高／體重／頭圍量測記錄）表＋RLS＋
-- list_growth_records／upsert_growth_record／delete_growth_record 三支 RPC
--
-- 設計稿（LS-252）尚未核可，本票只做資料模型與後端契約，不受呈現裁決（百分位帶／
-- feed 卡片／曲線切換）影響（LS-250「依賴」段：後端子票可先行）。
--
-- ---------------------------------------------------------------------------
-- 0. 為什麼這張表的 RLS 設計跟 diaries／albums／comments／children 不一樣
--
-- 這四張既有內容表最終都收斂成「直接 INSERT/UPDATE 一律拒絕、唯一寫入路徑是
-- SECURITY DEFINER RPC」（LS-48／LS-58／LS-66），起因都是「真的 RLS 直接開放寫入」
-- 曾經在 review 中被抓到具體漏洞：
--   - owner 分支的 grant 比 policy 意圖給的權力更寬，owner 藉此竄改別人內容
--     （不只是移除），diaries／comments 因此收斂（20260824010000／20260825020000）。
--   - 被降級成 viewer／已離開家庭的前作者，`author_id = 我` 這個靜態欄位沒有變，
--     仍能透過原本以為只看 author_id 的 policy 繼續寫（merge-reviewer PR #60 review
--     F2）。
--
-- 本票的 RLS 設計刻意避開這兩個漏洞類型，而不是重蹈覆轍再收斂一次：
--   1. **owner 完全不在 growth_records_update 的 USING/WITH CHECK 裡**——owner 對
--      內容編輯沒有任何直接權限（票面「更新只限作者」的字面意思），不會出現「owner
--      的 grant 比意圖更寬」這個問題，因為 owner 分支根本不存在。
--   2. **`family_id in (select private.contributor_family_ids())` 是即時子查詢**，
--      每次 UPDATE 都重新求值目前的成員狀態，不是快取的靜態欄位比對——被降級成
--      viewer 或已離開家庭的前作者，下一次呼叫這個子查詢就會回傳不含該家庭，
--      不會出現 F2 那種「author_id 沒變、舊授權繼續有效」的窗口。
-- 兩個歷史漏洞的根因都不是「RLS 直接開放寫入」本身，而是「policy 條件沒有正確表達
-- 意圖」；本票用同一個機制（真 RLS）但把條件寫對，不需要為了避開這兩個根因就整個
-- 收斂成 RPC-only。
--
-- 唯一無法只靠 author-scoped RLS 表達的是「owner 可以軟刪別人的紀錄」（票面「軟刪：
-- 作者或 owner」）——這需要在 UPDATE 的 USING/WITH CHECK 裡加入 owner 分支，但那樣
-- 會重新製造上面漏洞類型 1（owner 分支的 grant 若開在整個 UPDATE 上，owner 就能連
-- 內容一起改）。修法是「軟刪」根本不走一般 UPDATE 授權面：`deleted_at`／`deleted_by`
-- 兩欄對 authenticated 完全沒有 UPDATE grant（見下方 GRANT 段落），唯一路徑是
-- `delete_growth_record()`，這支因此必須是 SECURITY DEFINER（見該函式的說明）——
-- 這是本票對「RPC：security invoker 優先；若任一支需要 definer，寫明理由」的具體
-- 落地：list／upsert 兩支維持 invoker（分別依賴 select／insert／update 三條真
-- RLS），只有 delete 需要 definer。
--
-- ---------------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------------

create table public.growth_records (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  child_id uuid not null,
  author_id uuid references public.profiles (id) on delete set null,
  measured_on date not null,
  height_cm numeric(5, 1),
  weight_kg numeric(5, 2),
  head_cm numeric(5, 1),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles (id) on delete set null,
  -- 三項量測至少一項非空（票面：「三個量測至少一項非空」）
  constraint growth_records_measurement_required
    check (height_cm is not null or weight_kg is not null or head_cm is not null),
  -- 每一項若有填，必須是正值（票面：「數值 >0」；SQL 測試驗負值與 0 皆失敗）
  constraint growth_records_height_positive check (height_cm is null or height_cm > 0),
  constraint growth_records_weight_positive check (weight_kg is null or weight_kg > 0),
  constraint growth_records_head_positive check (head_cm is null or head_cm > 0),
  -- 備註長度上限（merge-review R1 m3）：沿 init_schema.sql 既有慣例——每一個
  -- 使用者輸入的文字欄都有上限（`children.name` 1–50、`albums.title` 1–100、
  -- `comments.body` 1–2000）。`note` 是選填欄位（可為 NULL），比照這個既有形狀，
  -- 有填的話一樣要求 1–2000（`comments.body` 同量級的自由文字備註，且 2000 字
  -- 對一則量測備註綽綽有餘；`btrim` 後長度 0 視同沒填，同 `children.name` 的
  -- 既有處理）。
  constraint growth_records_note_length
    check (note is null or char_length(btrim(note)) between 1 and 2000),
  -- 複合外鍵：孩子必須屬於同一個 family（同 diaries/albums 既有慣例）。child_id 在
  -- 這張表是 NOT NULL——一筆量測記錄不像日記／相簿可以是「全家共用、不掛特定孩子」，
  -- 量測的對象一定是某一個孩子；children 目前沒有硬刪路徑（LS-66 R1 I5），
  -- on delete cascade 純粹是型別正確性（NOT NULL 欄位不能 on delete set null），
  -- 實務上不會被觸發。
  constraint growth_records_child_same_family_fkey foreign key (family_id, child_id)
    references public.children (family_id, id) on delete cascade
);

comment on table public.growth_records is
  '身高／體重／頭圍量測記錄（LS-255，LS-250 後端先行）。INSERT／UPDATE（內容）走真正
  的 RLS（growth_records_insert／growth_records_update，作者本人＋仍是該家庭
  owner/member），不是 RPC-only 收斂——設計理由見本檔第 0 段。軟刪（deleted_at／
  deleted_by）兩欄對 authenticated 沒有任何 UPDATE grant，唯一寫入路徑是
  public.delete_growth_record()（SECURITY DEFINER）。';

comment on column public.growth_records.deleted_by is
  '軟刪這筆紀錄的人（LS-57 規則沿用，由 private.enforce_deletion_attribution()
  trigger 推導寫入，呼叫端無法指定）。NULL＝目前未刪除，或移除者的帳號後來被刪除。
  作者只能軟刪自己的（deleted_by 會是自己）；owner 對任何一筆的觸碰一律把
  deleted_by 覆寫成 owner 自己，且作者不能清除 owner 設下的 deleted_at——規則細節見
  20260825040000_deletion_attribution.sql 檔頭。';

-- 主查詢索引（票面明訂）：list_growth_records 依 child_id 等值＋measured_on 降冪，
-- 只覆蓋未刪列。
create index growth_records_child_measured_idx
  on public.growth_records (child_id, measured_on desc)
  where deleted_at is null;

-- FK 反向索引（65_fk_reverse_index.sql 會掃到三個外鍵：family_id 單獨、
-- (family_id, child_id) 複合、author_id、deleted_by）。上面的部分索引排除在 RI
-- 檢查之外（65_ 的既定規則：partial index 不算數，RI 要涵蓋已軟刪的列），因此
-- family_id／(family_id, child_id) 兩個外鍵需要一個非 partial 的複合索引；
-- author_id／deleted_by 兩個 profiles 外鍵各自需要單欄索引（同 diaries_author_idx／
-- children_deleted_by_idx 的既有慣例）。
create index growth_records_family_child_idx
  on public.growth_records (family_id, child_id);
create index growth_records_author_id_idx
  on public.growth_records (author_id);
create index growth_records_deleted_by_idx
  on public.growth_records (deleted_by);

alter table public.growth_records enable row level security;

-- ---------------------------------------------------------------------------
-- 2. RLS（讀／insert／update 三條真的會生效的 CREATE POLICY；票面「四條」裡的
--    「軟刪」落地成 GRANT 層全面封閉＋SECURITY DEFINER RPC，不是第四條 POLICY——
--    見下方「為什麼軟刪沒有獨立的 CREATE POLICY」）。
--
-- 為什麼軟刪沒有獨立的 CREATE POLICY（開發期間實測抓到的教訓，記錄下來避免重蹈）：
-- 本檔第一版確實多寫了一條 `growth_records_soft_delete`（USING/WITH CHECK 為
-- `owner 分支 or (author 分支)`），理由是「反正 deleted_at/deleted_by 沒有
-- UPDATE grant，這條 policy 求值不到，純粹防禦性宣告」。本機 `supabase db reset`
-- 加 `run.sh` 實測直接打臉這個假設：PostgreSQL 對同一個 command（這裡是
-- UPDATE）的多條 permissive policy 是用 **OR** 合併 USING/WITH CHECK，合併範圍
-- 是「這次 UPDATE 有沒有權限發生」，不是逐欄位判斷——`growth_records_soft_delete`
-- 的 owner 分支一旦為真，owner 對這次 UPDATE 涉及的**所有**欄位都會通過 RLS，
-- 不會被「這條 policy 原本只是為了 deleted_at/deleted_by」的意圖限制住。結果是
-- owner 透過 `upsert_growth_record` 的更新分支（只碰內容欄位，欄位級 GRANT 也
-- 開放）也能編輯別人的成長紀錄內容——跟第 0 段要避開的「owner 竟能竄改別人內容」
-- 一模一樣的漏洞，是本檔自己不小心重新引入的，不是假設性風險（`113_growth_
-- records.sql` §3 的「owner 不能編輯別人內容」斷言原地就地抓到）。
--
-- 修法：整條 `growth_records_soft_delete` policy 直接移除，不留著也不改寬鬆度——
-- 它想防禦的「deleted_at/deleted_by 被放寬 GRANT」情境，真正發生時（那本身已經
-- 是需要另一次 review 的變更）該由那次變更自己重新評估要不要加 policy，而不是
-- 讓一條「目前用不到、卻會在未來被悄悄允許 GRANT 放寬那一刻由 OR 合併偷渡出額外
-- 權限」的 policy 先埋在這裡。「owner 可以軟刪別人的紀錄」這件事完全由
-- `delete_growth_record()`（SECURITY DEFINER，繞過 RLS，函式內部手動判斷）承接，
-- 不需要、也不應該讓 RLS 層再插手 deleted_at 這個欄位。
-- ---------------------------------------------------------------------------

-- 讀：家庭成員（不分角色）可讀未刪的列。「未刪」直接收在 policy 裡（跟
-- diaries_select／comments_select 不同——那兩張表因為要支援「已刪除」佔位顯示與
-- owner 管理畫面，選擇不在 RLS 濾，改在呼叫端／RPC 濾；growth_records 沒有這個
-- 需求，票面明寫「可讀未刪」，直接收在 RLS 更簡單，也讓 list_growth_records 完全
-- 不需要在自己的 WHERE 裡重複這個條件）。
create policy growth_records_select on public.growth_records for select to authenticated
  using (
    family_id in (select private.family_ids())
    and deleted_at is null
  );

-- 新增：owner／member 皆可（viewer 不行，PLAN §3「Viewer 只能看與留言」——量測記錄
-- 是內容，跟 diaries/albums 同一條界線），author_id 必須是自己。
create policy growth_records_insert on public.growth_records for insert to authenticated
  with check (
    family_id in (select private.contributor_family_ids())
    and author_id = (select auth.uid())
  );

-- 更新（內容編輯）：**只有作者本人**，owner 不在這條 policy 裡（票面「更新只限
-- 作者」；owner 若也放進這條，會重蹈 diaries 當初「owner 竟能竄改別人內容」的覆轍，
-- 見第 0 段）。`family_id in contributor_family_ids()` 是即時子查詢，被降級成
-- viewer 或已離開家庭之後，這個條件會自然變成不成立，不會有「author_id 沒變、
-- 舊授權繼續有效」的窗口（第 0 段避開的第二類漏洞）。GRANT 只開放內容欄位（見下），
-- 這條 policy 因此不會被拿來竄改 deleted_at／deleted_by／family_id／child_id／
-- author_id。
create policy growth_records_update on public.growth_records for update to authenticated
  using (
    author_id = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  )
  with check (
    author_id = (select auth.uid())
    and family_id in (select private.contributor_family_ids())
  );

-- ---------------------------------------------------------------------------
-- 3. GRANT：SELECT 整表開放（列的可見性交給 RLS）；INSERT／UPDATE 皆欄位級收斂——
--    INSERT 不開放 id／created_at／updated_at／deleted_at／deleted_by（沿用預設值，
--    呼叫端不該指定）；UPDATE 只開放內容欄位，deleted_at／deleted_by／family_id／
--    child_id／author_id 一律不可直接寫（唯一路徑是 delete_growth_record()，見第 0
--    段）。新表預設對 authenticated 沒有任何權限（60_default_privileges.sql 第 1
--    段保證），這裡只需要正向 GRANT，不必先 REVOKE。
-- ---------------------------------------------------------------------------

grant select on public.growth_records to authenticated;

grant insert (family_id, child_id, author_id, measured_on, height_cm, weight_kg, head_cm, note)
  on public.growth_records to authenticated;

-- `updated_at` 一併開放：upsert_growth_record 的更新分支同一句 UPDATE 會把它
-- SET 成 now()（見第 6 段），Postgres 對 SET 子句提到的每一欄都要欄位級
-- UPDATE 權限，漏了這欄會讓整句 UPDATE 撞 42501（本機 supabase db reset 實測
-- 撞出來，非憑空假設）；不開放給呼叫端「指定」任意值的疑慮不成立——`updated_at`
-- 唯一被寫入的地方就是這句 UPDATE 語句本身寫死的 `now()`，呼叫端的參數列表裡
-- 根本沒有 `p_updated_at` 可以指定別的值。
grant update (measured_on, height_cm, weight_kg, head_cm, note, updated_at)
  on public.growth_records to authenticated;

-- ---------------------------------------------------------------------------
-- 4. 軟刪 trigger：重用 LS-57 的共用函式（20260825040000_deletion_attribution.sql
--    private.enforce_deletion_attribution()）——函式本身不知道也不需要知道自己掛在
--    哪張表上，只依賴 deleted_at／deleted_by／family_id 三個同名欄位，growth_records
--    三者皆有，可以直接掛，不需要另外寫一份等價邏輯（票面「軟刪...沿 LS-57：
--    deleted_by 記錄，作者不得清除 owner 設下的 deleted_at」就是這支函式的既有行為）。
--
--    唯一目前會走到這支 trigger 的路徑是 delete_growth_record()（見下）——該 RPC
--    只會把 deleted_at 從 NULL 設成 now()，不支援還原方向。trigger 的「owner 觸碰
--    永遠覆寫歸屬」「非 owner 重複軟刪維持原歸屬」「還原鎖擋下非 owner 清除別人
--    設下的 deleted_at」三條規則因此目前只有「owner 對已被作者自刪的紀錄再次呼叫
--    delete_growth_record」這個情境會實際被觸發（歸屬升級成 owner）；還原鎖方向
--    (`deleted_at` 從非 NULL 變 NULL) 目前沒有任何 RPC 會產生，是面向未來的防線——
--    若之後有票要加「還原」功能，只要那支新 RPC 一樣是 SECURITY DEFINER 直接
--    UPDATE deleted_at，這支 trigger 已經會自動擋下作者想清除 owner 軟刪的嘗試，
--    不需要那張票重新實作一次 LS-57 的規則（跟 diaries/albums/comments/children
--    共用同一支函式的理由完全相同）。
-- ---------------------------------------------------------------------------
--
-- merge-review R1 m1（informational，可選）：`v_label` 的 CASE 沒有
-- `growth_records` 分支，`LS027` 訊息會掉到 `else` 的泛稱「這筆內容」。這裡用
-- `CREATE OR REPLACE FUNCTION` 覆寫函式本體（只加一個 CASE 分支，其餘邏輯逐字
-- 不變，比照 20260825040000_deletion_attribution.sql 檔尾覆寫
-- `enforce_children_family_immutable()` 的既有慣例）——**不修改**
-- `20260825040000_deletion_attribution.sql` 那個檔案本身（已併入 main，
-- append-only）。

create or replace function private.enforce_deletion_attribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_label text;
  v_is_owner boolean;
begin
  v_label := case tg_table_name
               when 'diaries' then '這篇日記'
               when 'albums' then '這本相簿'
               when 'comments' then '這則留言'
               when 'growth_records' then '這筆成長紀錄'
               else '這筆內容'
             end;

  if new.family_id is distinct from old.family_id then
    raise exception '% 所屬的家庭不可變更（family_id 是不可變欄位，LS-57）', v_label
      using errcode = '42501';
  end if;

  if new.deleted_by is null
     and old.deleted_by is not null
     and to_jsonb(new) - 'deleted_by' = to_jsonb(old) - 'deleted_by' then
    return new;
  end if;

  if new.deleted_at is not distinct from old.deleted_at then
    return new;
  end if;

  v_uid := auth.uid();

  v_is_owner := exists (
    select 1 from public.family_members m
     where m.family_id = old.family_id and m.user_id = v_uid and m.role = 'owner'
  );

  if v_is_owner then
    if new.deleted_at is null then
      new.deleted_by := null;
    else
      new.deleted_by := v_uid;
    end if;
    return new;
  end if;

  if old.deleted_at is not null and old.deleted_by is distinct from v_uid then
    raise exception '% 已被家庭管理者移除，只有管理者能還原', v_label
      using errcode = 'LS027';
  end if;

  if new.deleted_at is null then
    new.deleted_by := null;
  elsif old.deleted_at is null then
    new.deleted_by := v_uid;
  else
    new.deleted_by := old.deleted_by;
  end if;

  return new;
end;
$$;

create trigger growth_records_deletion_attribution
  before update on public.growth_records
  for each row execute function private.enforce_deletion_attribution();

-- ---------------------------------------------------------------------------
-- 4b.（merge-review R1 m2）已軟刪的孩子不能再被指定為新內容——重用 LS-66/LS-121
-- 的共用函式 private.enforce_child_not_deleted()（20260825030000_children_write_
-- path_and_soft_delete.sql 定義，diaries／albums 的 BEFORE INSERT/UPDATE 已掛，見
-- 該函式檔頭：「已軟刪的孩子不能再被指定為新內容的 child_id」）。函式邏輯只依賴
-- `new.child_id`／`tg_op`／`old.child_id`（若存在）三者，不知道也不需要知道自己
-- 掛在哪張表，growth_records 有 `child_id` 欄位，可以直接掛，不必另寫一份等價
-- 邏輯。回傳既有碼 LS044（不新增碼，error-codes-check.sh 不受影響）。
--
-- 「既有內容不動」原則同 diaries／albums：只在 child_id 真的被指定新值時檢查
-- （INSERT 恆檢查；UPDATE 只在 `new.child_id is distinct from old.child_id` 時
-- 檢查）。growth_records 的 UPDATE 路徑（upsert_growth_record 的更新分支）從不
-- SET child_id（GRANT 也沒開放這欄，見第 3 段），因此這支 trigger 對 UPDATE
-- 永遠是 no-op、只有 INSERT 分支會真正生效——掛 `before insert or update` 純粹是
-- 跟 diaries／albums 的既有宣告形狀一致（面向未來：若日後 UPDATE 路徑真的開放
-- 改 child_id，這裡不需要回頭補）。
-- ---------------------------------------------------------------------------

create trigger growth_records_child_not_deleted
  before insert or update on public.growth_records
  for each row execute function private.enforce_child_not_deleted();

-- ---------------------------------------------------------------------------
-- 5. 掛上既有的兩支共用 guard trigger（LS-151／LS-179）——growth_records 是一張
--    帶 family_id 的「自著內容」表，跟 diaries／comments 同一類，沒有理由不受
--    這兩條既有防線保護，否則帳號刪除過渡期／停權期間仍能透過
--    upsert_growth_record() 建立新的成長紀錄，是實質的縱深防禦漏洞，不是本票
--    刻意留白。兩支函式都已在更早的 migration 定義，這裡只是新增
--    `CREATE TRIGGER` 把 growth_records 掛進既有機制，不需要重新定義函式本體。
-- ---------------------------------------------------------------------------

-- LS-151：deletion_requested_at 非 NULL 時擋新增（LS051）。只掛 BEFORE INSERT
-- （同 diaries／comments／children 等既有六張表的既定範圍——過渡期使用者不能
-- 建立新資料，但既有資料的軟刪／編輯不受影響）。
create trigger growth_records_deletion_guard
  before insert on public.growth_records
  for each row execute function private.enforce_account_not_deletion_requested();

-- LS-179：帳號／家庭被停權時擋 INSERT/UPDATE/DELETE（LS052／LS053）。growth_records
-- 沒有 DELETE 路徑（見第 3 段 GRANT），這裡仍比照 children／diaries 等既有表的既定
-- 慣例掛滿三種操作——DELETE 分支對這張表恆為 no-op（沒有任何呼叫端能觸發 DELETE
-- 語句），純粹是跟其餘表維持同一種宣告形狀，不是遺留的可利用路徑。
create trigger growth_records_not_suspended
  before insert or update or delete on public.growth_records
  for each row execute function private.enforce_not_suspended();

-- ---------------------------------------------------------------------------
-- 6. RPC
-- ---------------------------------------------------------------------------

-- list_growth_records：真正的 keyset 分頁（measured_on desc, id desc）。
--
-- **R1 訂正（merge-reviewer PR #392 review M1，major）**：R1 版本只用
-- `p_before date` 單值游標（`measured_on < p_before`），reviewer 實跑重現：同一
-- child 4 筆（D1 單獨一天、D2a／D2b 同一天、D3 更早一天），`p_limit=2` 分頁——
-- page1={D1,D2a}，游標取 page1 最後一筆的 measured_on，page2({p_before=D2 那天})
-- 只回 {D3}，**D2b 從此拿不回來**（`measured_on < p_before` 的嚴格不等式把整個
-- D2 那天都排除，包括還沒被 page1 涵蓋的 D2b）——票面明訂「同一 child 同日多筆
-- 允許」「同日多筆取最後由讀端處理」，讀端要能「取最後」的前提是看得到該日
-- **全部**列，這個漏洞會讓被漏掉的那筆若剛好是當天最新一筆，最新值卡／曲線就
-- 吃到過期資料。
--
-- 修法：改成真正的 2 元組 keyset 游標 `(measured_on, id) < (p_before, p_before_id)`
-- ——新增 `p_before_id uuid default null` 參數，呼叫端從上一頁最後一列的
-- `id`（連同 `measured_on`）帶進來。用 `id` 而不是 `created_at` 當同一天的
-- tie-break（不是 `get_family_timeline` 的 `(occurred_at, ref_id)` 或
-- `media_family_created_idx` 的 `(created_at, id)` 兩種既有寫法的隨機挑選）：
-- `id` 是主鍵，結構上保證每一列互不相同，`created_at` 雖然本表大多數情況下也是
-- 唯一的，但同一交易內連續呼叫 `upsert_growth_record` 會拿到同一個 `now()`
-- （transaction_timestamp 語意，同 88_deletion_attribution.sql 檔頭的既有
-- 說明——本票 `113_growth_records.sql` 開發期間就實際踩過這個陷阱，見該檔 §8
-- 的處理方式）——用 `id` 完全迴避這個collision 風險，不需要額外假設呼叫端一定是
-- 分開的交易。`ORDER BY`／索引使用的排序鍵因此也從 `created_at desc` 改成
-- `id desc`；`created_at` 仍是回傳列的一個欄位（讀端如果真的需要用建立時間排序
-- 「同日多筆取最後」，資料還在，只是本 RPC 自己的排序鍵不再依賴它）。
--
-- 半游標檢查沿用既有碼 `LS022`（`get_family_timeline`／`list_comments` 已經在用
-- 的同一個碼，語意完全相同——「keyset 分頁的游標參數只給了一半」，不新增碼、
-- `docs/API.md` §5 只需要把 `list_growth_records` 加進這個碼的觸發清單）。
--
-- security invoker（未寫 security definer，同 list_children／get_family_timeline
-- 的既有慣例）：完全依賴 growth_records_select RLS（family 成員＋未刪），呼叫端
-- 傳一個自己不屬於的 p_child_id 不會報錯，只會回傳 0 列。
--
-- 拆成 if/else 兩個靜態查詢分支（不是同一句 SQL 裡的 `p_before is null or ...`
-- OR 條件）：20260824010000_diaries_write_path_and_timeline.sql 第 4 段（review
-- F1）實測過 OR 條件會讓規劃器選不到部分索引、整段落到 Filter 逐列判斷，這裡直接
-- 沿用那次學到的寫法，不重蹈覆轍。
create or replace function public.list_growth_records(
  p_child_id uuid,
  p_limit integer default 50,
  p_before date default null,
  p_before_id uuid default null
)
returns setof public.growth_records
language plpgsql
stable
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if (p_before is null) <> (p_before_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_before／p_before_id）'
      using errcode = 'LS022';
  end if;

  if p_before is null then
    return query
      select g.*
        from public.growth_records g
       where g.child_id = p_child_id
       order by g.measured_on desc, g.id desc
       limit v_limit;
  else
    return query
      select g.*
        from public.growth_records g
       where g.child_id = p_child_id
         and (g.measured_on, g.id) < (p_before, p_before_id)
       order by g.measured_on desc, g.id desc
       limit v_limit;
  end if;
end;
$$;

revoke execute on function public.list_growth_records(uuid, integer, date, uuid) from public, anon;
grant execute on function public.list_growth_records(uuid, integer, date, uuid) to authenticated;

-- upsert_growth_record：p_id 為 NULL＝新增（owner/member 皆可，author_id 一律是
-- 呼叫者本人）；p_id 非 NULL＝更新內容（僅原作者，且仍是該家庭 owner/member——見
-- growth_records_update policy）。security invoker（未寫 security definer）：
-- 完全依賴 growth_records_insert／growth_records_update 兩條真 RLS，不做任何手動
-- 授權判斷——這是本票「RPC：security invoker 優先」的具體體現，也是刻意的技術
-- 選擇：單一 INSERT／UPDATE 陳述式本身就是原子操作，授權判斷（RLS）與寫入在同一
-- 個陳述式內完成，不像 create_diary_entry 那類 DEFINER RPC 需要先
-- `SELECT ... FOR UPDATE` 讀出目前狀態再手動判斷（那是為了在「讀」與「寫」兩個
-- 步驟之間插入手動檢查而必須付出的 TOCTOU 防護代價）；這裡沒有那個代價，也就沒有
-- 那個風險。
--
-- 新增分支：child_id 對應的 family_id 用一句 SELECT 解出（children_select RLS
-- 允許同家庭任何角色讀取，含 viewer——但 viewer 接下來的 INSERT 仍會被
-- growth_records_insert 的 WITH CHECK 擋下，是兩個獨立的授權層）。p_child_id
-- 不存在、或指向呼叫者未加入的家庭，這句 SELECT 回 NULL，INSERT 帶著
-- family_id = NULL 送出——**本機實測結果（不是猜測）**：PostgreSQL 對 INSERT
-- 是先評估 RLS 的 WITH CHECK、才輪到欄位的 NOT NULL 約束，`NULL in (select
-- private.contributor_family_ids())` 求值為 NULL（不是 TRUE），WITH CHECK 判定
-- 為不通過，實際冒出來的是標準的 RLS 違反訊息（`new row violates row-level
-- security policy`，`42501`），不是原本預期的 `23502`（not_null_violation）——
-- 開發期間第一版文件／測試曾經誤寫成 23502，本機 `supabase db reset` 一跑就露餡
-- （`113_growth_records.sql` §7 的斷言原地就抓到），已訂正為實測結果。
-- 刻意不開自訂碼：本票是純後端票，不動 Swift（`LittleSprout/Errors/
-- AppError.swift`），`error-codes-check.sh` push-gate 要求任何新的自訂 LSnnn 碼
-- 必須同時登記在 docs/API.md §5 與 Swift 的 LSErrorCode，兩者是同一個 PR 的兩
-- 件事；本票不動 Swift，因此全程只用既有的標準碼（42501／23514），不新增任何
-- LSnnn。若日後 iOS 實作票需要對「找不到孩子」與「一般 RLS 拒絕」給不同文案，
-- 屆時那張票可以另開自訂碼、同 PR 補 Swift enum。
--
-- 更新分支：UPDATE 命中 0 列時，唯一可能原因是「id 不存在」或「你不是這筆紀錄的
-- 作者（或已不是該家庭 owner/member）」——RLS 的 USING 子句對呼叫者不可見的列
-- 一律回 0 列，兩種情況在這裡故意不區分（比照 list_children／get_family_timeline
-- 「查不到就是 0 列，不報特定錯誤」的既有精神，這裡因為是寫入操作才額外 raise 一個
-- 通用的 42501，讓呼叫端至少知道這次更新沒有生效），一樣不開自訂碼。
create or replace function public.upsert_growth_record(
  p_id uuid,
  p_child_id uuid,
  p_measured_on date,
  p_height_cm numeric,
  p_weight_kg numeric,
  p_head_cm numeric,
  p_note text
)
returns public.growth_records
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_family uuid;
  v_row public.growth_records%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法新增或編輯成長紀錄' using errcode = '42501';
  end if;

  if p_id is null then
    select c.family_id into v_family from public.children c where c.id = p_child_id;

    insert into public.growth_records
      (family_id, child_id, author_id, measured_on, height_cm, weight_kg, head_cm, note)
    values
      (v_family, p_child_id, v_uid, p_measured_on, p_height_cm, p_weight_kg, p_head_cm, p_note)
    returning * into v_row;
  else
    update public.growth_records g
       set measured_on = p_measured_on,
           height_cm = p_height_cm,
           weight_kg = p_weight_kg,
           head_cm = p_head_cm,
           note = p_note,
           updated_at = now()
     where g.id = p_id
    returning * into v_row;

    if not found then
      raise exception '成長紀錄不存在，或您不是這筆紀錄的作者，無法編輯' using errcode = '42501';
    end if;
  end if;

  return v_row;
end;
$$;

revoke execute on function
  public.upsert_growth_record(uuid, uuid, date, numeric, numeric, numeric, text)
  from public, anon;
grant execute on function
  public.upsert_growth_record(uuid, uuid, date, numeric, numeric, numeric, text)
  to authenticated;

-- delete_growth_record：軟刪，作者本人（且仍是該家庭成員，門檻同
-- set_diary_deleted——「移除自己貢獻過的東西」不因被降級而被剝奪，但完全離開家庭
-- 之後關閉）或該家庭 owner（不要求仍是 contributor，owner 對全家內容的移除權限
-- 不受角色細分限制，同 set_diary_deleted／set_album_deleted 的既有慣例）。
--
-- **必須是 SECURITY DEFINER**：deleted_at／deleted_by 兩欄對 authenticated 沒有
-- 任何 UPDATE grant（第 3 段），這是本表唯一真正的軟刪路徑；且「owner 可以移除
-- 別人的紀錄」這件事無法只靠 author-scoped 的 growth_records_update 表達（把 owner
-- 加進那條 policy 會連內容欄位一起開放給 owner，違反「更新只限作者」——見第 0
-- 段）。DEFINER 以 table owner 身分執行，繞過欄位級 grant，函式內部的手動授權
-- 檢查取代 RLS。`set search_path = ''` 收斂（LS-224 慣例）。
--
-- 只有單一方向（軟刪，NULL → now()），沒有 p_deleted 參數／還原方向——票面範圍
-- 只要求 `delete_growth_record(p_id)`，還原功能留給日後的票（見第 4 段 trigger
-- 說明：即使日後加還原 RPC，只要一樣是 DEFINER 直接 UPDATE，LS-57 的還原鎖已經
-- 就位，不需要重新設計）。
--
-- `FOR UPDATE` 鎖住目標列再讀 family_id／author_id 做授權判斷（LS-52 既定規則：
-- RPC 授權判斷讀到的列都要先鎖住，防 TOCTOU）。
create or replace function public.delete_growth_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_rec public.growth_records%rowtype;
  v_is_owner boolean;
  v_is_current_member boolean;
begin
  if v_uid is null then
    raise exception '未登入，無法移除成長紀錄' using errcode = '42501';
  end if;

  select g.* into v_rec from public.growth_records g where g.id = p_id for update;

  if not found then
    raise exception '找不到這筆成長紀錄' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_rec.family_id and m.user_id = v_uid and m.role = 'owner'
  ) into v_is_owner;

  select exists (
    select 1 from public.family_members m
     where m.family_id = v_rec.family_id and m.user_id = v_uid
  ) into v_is_current_member;

  if not v_is_owner
     and (v_rec.author_id is distinct from v_uid or not v_is_current_member) then
    raise exception '只有作者本人（且仍是該家庭成員）或該家庭的 owner 能移除這筆成長紀錄'
      using errcode = '42501';
  end if;

  update public.growth_records g set deleted_at = now() where g.id = p_id;
end;
$$;

revoke execute on function public.delete_growth_record(uuid) from public, anon;
grant execute on function public.delete_growth_record(uuid) to authenticated;
