-- LS-197（LS-23 後端切片）— EULA 同意紀錄
--
-- 來源：LS-190（iOS EULA 同意頁：首次登入／版本更新時顯示零容忍條款摘要，需同意
-- 才進 app）的後端前置。App Store 5.1.1／UGC 指引要求可證明使用者同意過含零容忍
-- 條款的 EULA（docs/PLAN.md §6 第 7 項／§10-B）。
--
-- 設計摘要：
--   1. `app_settings.eula_version`：目前要求同意的條款版本字串，比照 LS-179
--      `registrations_open` 放在同一張單列設定表，由表擁有者（Dashboard／
--      `supabase db query --linked`）手動 UPDATE 這一欄即生效，不改程式碼。
--      跟 `registrations_open` 不同的一點：client 需要知道「現在要哪個版本」
--      才能決定要不要跳出同意頁、以及呼叫 `accept_eula()` 時該送哪個版本作
--      `p_version`——這裡刻意開一道欄位級 SELECT（只有這一欄），不是沿用
--      `registrations_open()` 那種「完全不讓 client 摸到、只讓內部 trigger 讀」
--      的封閉模式。兩者共通點是「只有表擁有者能寫」；差別只在「client 讀不讀
--      得到」，依各自實際需要各自決定，不是同一件事。
--   2. `profiles.eula_accepted_version`／`eula_accepted_at`：使用者最近一次同意
--      的版本與時間。跟 `deletion_requested_at`（LS-143）／`suspended_at`
--      （LS-179）用同一招式擋 client 直接寫入：`authenticated` 對 `profiles`
--      的 UPDATE grant 早在 LS-143（`20260903084231_delete_account.sql`）就已經
--      「先收回整表、只重開 `display_name`／`avatar_url` 兩欄」，這裡新增的兩欄
--      天生不在那個允許清單內，不需要另外下任何 REVOKE 就已經擋掉 client 直接
--      `.update()`；讀取則沿用 `profiles` 既有的表級 SELECT grant，新欄位自動
--      被涵蓋（同一欄位註解慣例，見 `suspended_at`）。
--   3. `accept_eula(p_version text)`：SECURITY DEFINER，版本比對＋寫入兩欄。
--      不需要額外的停權豁免邏輯——`private.enforce_not_suspended()` 涵蓋的表
--      清單裡沒有 `profiles`（見 `20260904212530_suspension_and_registrations.sql`
--      第 3 段的範圍決策：profiles 本身刻意不掛任何停權判斷），這支函式寫入的
--      正是 `profiles`，加上函式本身是 SECURITY DEFINER（以表擁有者身分執行，
--      寫入不經過 `profiles_update` policy），停權者呼叫天生暢通。這跟
--      `delete_my_account()` 需要額外的交易級 GUC 逃生口不同：那支函式寫的是
--      掛了 `enforce_not_suspended` trigger 的表（`family_members`／`diaries`…），
--      這支寫的是完全沒掛這支 trigger 的 `profiles`，不需要比照那個逃生口機制。
--      冪等：函式本體永遠是「比對版本→通過就 UPDATE 兩欄」，同版本重複呼叫
--      不會報錯，只是 `eula_accepted_at` 被覆寫成最新一次呼叫的時間——沒有
--      「已經是這個版本就整支跳過」的分支，因為需求是留下「最近一次確認過
--      條款」的時間戳，不是「最早一次同意」的時間戳。
--
-- 新錯誤碼 `LS055`：`p_version` 與 `app_settings.eula_version` 目前值不相等時
-- 觸發（docs/API.md §5）。用 `is distinct from` 而不是 `<>`（比照
-- `notification_recipients()` 既有慣例）：`p_version` 是呼叫端傳入的參數，NULL
-- 時 `<>` 的三值邏輯結果是 NULL、不會落進 IF 判斷，`is distinct from` 才能正確
-- 把「沒給版本」也判成不相符。
-- ---------------------------------------------------------------------------

alter table public.app_settings
  add column eula_version text not null default '2026-09-05-draft';

comment on column public.app_settings.eula_version is
  'LS-197（PLAN §6 第 7 項／§10-B）：目前要求同意的 EULA 版本字串，初值是佔位
  草稿版號——LS-132 法務正式文本核可後由表擁有者（Dashboard／
  supabase db query --linked）手動 UPDATE 這一欄即生效。跟本表其餘欄位不同，
  這一欄對 authenticated 開了欄位級 SELECT（見下方 grant／policy）：client 需要
  讀到目前版本才能判斷是否該跳出同意頁、呼叫 accept_eula() 時該送哪個版本；
  registrations_open／updated_at／id 仍維持原本的完全不可讀。';

-- 欄位級 SELECT：只開這一欄，其餘欄位（id／registrations_open／updated_at）
-- 沒有任何 grant，PostgREST 對它們的請求一律 42501。**client 端查詢不能帶
-- `where id = true`**——Postgres 的欄位級權限檢查涵蓋查詢裡任何位置「引用」到
-- 的欄位，不只是投影出來的欄位，WHERE 子句用到 `id` 一樣需要 `id` 的 SELECT
-- 權限（本檔開發期間實測撞過一次 `permission denied for table app_settings`，
-- 見 `supabase/tests/106_eula_consent.sql`）。本表只有一列（見表定義的 CHECK），
-- 客戶端直接 `select eula_version from app_settings`（不帶任何 WHERE）即可，
-- 不需要、也不能篩 `id`；`§11` 那些帶 `where id = true` 的查詢是表擁有者
-- （postgres）身分執行，不受這道欄位級 grant 限制，兩者是不同的執行身分。
grant select (eula_version) on public.app_settings to authenticated;

-- RLS 已啟用（20260904212530_suspension_and_registrations.sql）但這張表原本
-- 沒有任何 policy——「有 column grant 但沒有 policy」＝所有列一律被篩掉
-- （SELECT 回 0 列，不是錯誤），上面那句 grant 若不搭一條 SELECT policy 會是
-- 沒有效果的死授權。單列表（`id` 恆為 `true`，見表定義的 CHECK），
-- `using (true)` 不會洩漏比「這張表存在一列設定」更多的資訊，且能看到的欄位
-- 仍受上面的欄位級 grant 收斂（只有 eula_version）。
create policy app_settings_select on public.app_settings for select to authenticated
  using (true);

alter table public.profiles
  add column eula_accepted_version text,
  add column eula_accepted_at timestamptz;

comment on column public.profiles.eula_accepted_version is
  'LS-197：使用者最近一次呼叫 accept_eula() 成功時的 app_settings.eula_version
  值。NULL＝從未同意過。authenticated 對 profiles 的 UPDATE grant 早在 LS-143
  （20260903084231_delete_account.sql）就已收斂成只開 display_name／avatar_url
  兩欄，這一欄不在那個允許清單內，天生擋掉直接 .update()，只能透過
  accept_eula() 寫入——不需要另外下 REVOKE（同 suspended_at／
  deletion_requested_at 的既有機制）。讀取沿用 profiles 既有的表級 SELECT
  grant，新欄位自動被涵蓋。';

comment on column public.profiles.eula_accepted_at is
  'LS-197：上面那一欄對應的同意時間戳（accept_eula() 內用 now() 寫入）。同一
  版本重複呼叫 accept_eula() 會把這一欄覆寫成最新一次呼叫的時間——冪等，不是
  「已經同意過這個版本就整支跳過」，因為需求是留下最近一次確認過條款的時間，
  不是最早一次同意的時間。';

create or replace function public.accept_eula(p_version text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_current text;
begin
  if v_uid is null then
    raise exception '未登入，無法紀錄同意' using errcode = '42501';
  end if;

  select a.eula_version into v_current from public.app_settings a where a.id = true;

  if p_version is distinct from v_current then
    raise exception '條款版本已更新，請重新閱讀' using errcode = 'LS055';
  end if;

  update public.profiles
     set eula_accepted_version = p_version,
         eula_accepted_at = now()
   where id = v_uid;
end;
$$;

revoke execute on function public.accept_eula(text) from public, anon;
grant execute on function public.accept_eula(text) to authenticated;

comment on function public.accept_eula(text) is
  'LS-197：紀錄呼叫者同意 p_version 版本的 EULA。p_version 必須等於當下的
  app_settings.eula_version，否則回 LS055（多半是呼叫端讀到的版本已經過期，
  UI 該重新抓一次目前版本再顯示條款）。SECURITY DEFINER，寫入不經過
  profiles_update policy，也不掛 private.enforce_not_suspended()（那支 trigger
  沒有掛在 profiles 上，見本檔檔頭第 3 點）——停權中的使用者仍能呼叫，同意
  條款不是內容寫入，理由同 delete_my_account() 對停權的豁免（PLAN §10-B）。
  冪等：同版本重複呼叫不報錯，eula_accepted_at 更新為最新一次。';
