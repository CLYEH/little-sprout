-- LS-179（LS-23 後端切片）— 營運防線：使用者／家庭停權旗標＋註冊開關
--
-- 來源：docs/PLAN.md §10-A(3)（備案：註冊開關，爆量時唯一能立刻止血的手段）與
-- §10-B（要有停權能力：能停掉特定使用者或整個家庭，不需要改程式碼）。兩者都是
-- Dashboard 手動改一個欄位就生效，不改任何程式碼——本檔要做的是讓「改欄位」這個
-- 動作真的擋得住東西。
--
-- ---------------------------------------------------------------------------
-- 設計總覽（先講「為什麼長這樣」，下面每一段各自的理由不重複貼一次）
--
-- 停權要擋兩個完全不同的入口，各自需要不同機制，兩者缺一不可：
--
--   1. **直接走 RLS 的路徑**（PostgREST 直接 `.select()`/`.insert()`/`.update()`/
--      `.delete()`，以及 storage.objects 的四條 policy）：這條路徑沒有辦法回自訂
--      錯誤碼（RLS 违反一律是 Postgres 標準的 42501／靜默 0 列），但可以透過
--      `private.family_ids()`／`owned_family_ids()`／`contributor_family_ids()`／
--      `uploadable_family_ids()` 這四支既有的 STABLE SECURITY DEFINER 集合函式
--      （20260822120200_rls_policies.sql）一次性收斂——幾乎每一條 `_select` policy
--      與大部分直接寫入 policy 都經過這四支，本檔把停權判斷塞進去，等於一次改動
--      cascade 到十幾張表的 SELECT，也順帶讓 20260823030000_storage_policies.sql
--      的 storage.objects policy（同樣呼叫這四支函式）自動排除停權者的新上傳／新
--      簽名——這正是票面「上傳簽名」那個檢查點，見該檔的既有註解。
--
--   2. **走 SECURITY DEFINER RPC 的路徑**（create_child／create_diary_entry／
--      toggle_reaction／approve_join／delete_my_account…）：這些函式以表擁有者
--      身分執行、繞過 RLS，上面那組 policy 判斷完全管不到它們。但 SECURITY
--      DEFINER **不會**繞過 table trigger——這正是 LS-151（deletion_requested_at
--      過渡期擋寫，20260903115014_delete_account_edge_support.sql）已經驗證過的
--      機制：掛在底層表的 BEFORE INSERT/UPDATE/DELETE trigger，不論呼叫路徑是直接
--      client 寫入還是包在哪一支 RPC 裡面，都會確實觸發。本檔比照同一手法，掛一支
--      共用 trigger `private.enforce_not_suspended()` 到全部帶 family_id 的內容表，
--      同時處理「呼叫者本人停權」（LS052）與「該筆資料所屬家庭停權」（LS053）兩種
--      情況，並且是唯一能回**自訂**錯誤碼給呼叫端的機制（RLS 做不到這件事）。
--
--   兩者疊加：SELECT 與 Storage 走機制 1，INSERT/UPDATE/DELETE（不論直接寫入或
--   RPC）走機制 2。三支唯讀 SECURITY DEFINER RPC（list_join_requests／
--   get_my_join_request／list_comments）兩種機制都碰不到（沒有寫入、又繞過 RLS
--   讀），本檔逐支加明確檢查，見第 6 段。
--
-- 停權判斷本身只讀 `profiles.suspended_at`／`families.suspended_at`（SECURITY
-- DEFINER helper，票面規定）。
--
-- 範圍刻意排除的兩塊（都寫在對應段落，這裡先列清單，避免看起來像遺漏）：
--   - `profiles` 表本身（自己的 SELECT／UPDATE）不掛任何停權判斷——見第 3 段。
--   - `device_tokens` 不掛 trigger——見第 5 段結尾。
--
-- merge-review R1（`23fa5e37`）R2 訂正（本檔直接修改——這個 migration 從未併入
-- origin/development，append-only的限制只保護「已併入」的檔案，見
-- docs/COLLABORATION.md／migration-immutable-check.sh 的判定範圍）：
--   MAJOR-1：`suspended_reason` 原本設計成 `profiles`／`families` 的一般欄位，
--   但這兩張表對 `authenticated` 是**表級** SELECT grant（不是逐欄），任何後來
--   `add column` 的欄位都會自動被表級 SELECT 涵蓋——本檔原本「新增欄位天生不可讀」
--   的判斷是錯的（已實測：停權者一句 `select suspended_reason from profiles`
--   就讀得到稽核原因）。改法：`suspended_reason` 完全不放在這兩張表上，搬進
--   全新的 `private.suspension_notes`（見第 0b 段）——`private` schema 對
--   `authenticated`／`anon` 只有 `usage`（見 20260822120000_init_schema.sql:16-17），
--   沒有任何表格級 grant，新建的表預設不對它們開放任何權限，不需要動
--   `profiles`／`families` 既有的表級 SELECT（不動既有讀取面）。`suspended_at`
--   維持在原表上、可讀無妨（client 本來就會從 LS052／LS053 得知停權事實，
--   `suspended_at` 只是同一件事的時間戳，不是額外的資訊揭露）。
--   MAJOR-2：`delete_my_account()`（App Store Guideline 5.1.1(v)／PLAN §9-A2）
--   不得被停權連帶封死——見第 8 段。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 0. schema：停權旗標＋註冊開關設定表
--
-- 索引：`caller_is_active()`／`family_is_active()` 兩支 helper 都是對 PK 的等值
-- 查詢（`profiles.id`／`families.id` 皆為 primary key，天生有 btree 索引），不是
-- 全表掃描，也不是逐列比對 `suspended_at`——不需要額外的 partial index。這兩支
-- helper 只會在「我所屬的少數幾個家庭」這種本來就很小的集合上逐列呼叫一次（見
-- 第 2 段 family_ids() 等函式的改法），不是套用在 media／diaries 這種大表的
-- 每一列上，成本量測見 PR body。
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column suspended_at timestamptz;

comment on column public.profiles.suspended_at is
  'LS-179（PLAN §10-B）：Dashboard 手動 UPDATE 這一欄即生效，不改程式碼。非 NULL
  時，這個使用者對「所有」家庭資料（不限於他目前所屬的家庭）的 RLS 讀寫與既有
  RPC 入口一律拒絕，見 private.caller_is_active()／private.enforce_not_suspended()。
  不影響其他使用者。解除＝設回 NULL。停權原因不放在這裡（R2：見
  private.suspension_notes 與下方第 0b 段——`authenticated` 對本表是表級 SELECT
  grant，任何欄位都會被自動涵蓋，稽核原因不能放在這張表上）。';

alter table public.families
  add column suspended_at timestamptz;

comment on column public.families.suspended_at is
  'LS-179（PLAN §10-B）：Dashboard 手動 UPDATE 這一欄即生效。非 NULL 時，這個家庭
  的全部成員（不分角色）對這個家庭的資料一律拒絕讀寫；成員對「其他」家庭不受
  影響（Phase 3 多家庭前置）。見 private.family_is_active()／
  private.enforce_not_suspended()。停權原因不放在這裡（R2，理由同
  public.profiles.suspended_at 的欄位註解）。';

-- client 讀得到這兩欄（authenticated 對 profiles／families 本來就是表級 SELECT
-- grant，見 20260822120000_init_schema.sql／20260903084231_delete_account.sql，
-- 新增的 `suspended_at` 自然被涵蓋）——這是刻意的，不是疏漏：停權事實本來就會
-- 從每一次操作失敗的 LS052／LS053 揭露，`suspended_at` 只是同一件事的時間戳，
-- 不構成額外資訊洩漏。`suspended_at` 沒有 UPDATE grant（client 改不動，只能靠
-- service_role／表擁有者），見下方 app_settings 之後的 R2 補充段落。

-- ---------------------------------------------------------------------------
-- 0b.（R2，MAJOR-1）稽核用的停權原因——只有表擁有者／service_role 讀得到
--
-- 不放在 profiles／families 上（見上方欄位註解的理由），改放這張純內部表。
-- `private` schema 對 authenticated／anon 只有 `usage`（20260822120000_
-- init_schema.sql:16-17：`revoke all on schema private from public` ＋
-- `grant usage on schema private to authenticated`），沒有任何表格級
-- SELECT／INSERT／UPDATE／DELETE grant；USAGE 只讓你能在 SQL 裡「引用」
-- schema 內的物件名稱，不等於能讀寫裡面的表——這張表完全沒有下任何
-- `grant ... to authenticated` 語句，所以是預設拒絕（`42501 permission
-- denied for table suspension_notes`），不需要 RLS（沒有任何非 owner 角色有
-- 任何 table privilege 可言，RLS 只在「已經有 grant 但要進一步依列篩選」時
-- 才有意義，這裡連 grant 都沒有）。
--
-- 一個停權主體（使用者或家庭）同時最多一筆備註（`primary key (subject_type,
-- subject_id)`）——這是稽核備註不是歷史留言板，重新停權／換一個原因就是
-- upsert 覆蓋，解除停權時一併刪除（見 §11 手冊），語意對齊原本
-- `suspended_reason = NULL` 代表「沒有進行中的停權原因」的既有設計。
-- ---------------------------------------------------------------------------
create table private.suspension_notes (
  subject_type text not null check (subject_type in ('user', 'family')),
  subject_id uuid not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (subject_type, subject_id)
);

comment on table private.suspension_notes is
  'LS-179 R2（MAJOR-1）：停權原因的稽核備註，只有表擁有者（postgres，Dashboard／
  `supabase db query --linked`）與 service_role（若日後另外 grant）讀寫得到。
  故意不放在 public.profiles／public.families——那兩張表對 authenticated 是
  表級 SELECT，任何欄位都會被自動涵蓋，稽核原因不能放在那裡。';

create table public.app_settings (
  -- 單列表：id 恆為 true，CHECK 保證永遠只有一列，不需要另外的唯一性判斷。
  id boolean primary key default true check (id),
  registrations_open boolean not null default true,
  updated_at timestamptz not null default now()
);

comment on table public.app_settings is
  'LS-179（PLAN §10-A(3)）：全域營運開關，目前只有 registrations_open 一欄。單列表
  ——Dashboard 手動 UPDATE 這一欄（`where id = true`）即生效，不改程式碼。只有
  表擁有者（postgres，透過 Dashboard／`supabase db query --linked`）能寫（RLS
  沒有任何 INSERT/UPDATE/DELETE policy，且 authenticated 沒有對應的 table
  grant，見下方）；`service_role` 目前也沒有這幾個表的寫入 grant（`BYPASSRLS`
  只繞過 RLS、不等於有 table privilege，R2 merge-review m4 實測 catalog 確認），
  若之後有 Edge Function 需要直接寫入，須另外明確
  `grant insert, update, select on public.app_settings to service_role`。
  authenticated 只能透過 private.registrations_open() 讀單一布林值，不開放
  整表 SELECT 給 client（沒有理由讓 client 看到 updated_at 之類的欄位）。';

insert into public.app_settings (id, registrations_open) values (true, true);

alter table public.app_settings enable row level security;

-- 沒有 grant 給 authenticated：這張表完全不對 client 開放直接讀寫，唯一的讀取
-- 路徑是下面的 private.registrations_open()（SECURITY DEFINER，繞過 RLS）。
-- 因此這裡也不需要任何 policy——RLS 啟用但沒有 policy＝對 authenticated/anon
-- 全部拒絕，符合「只有表擁有者可寫，client 只能透過 helper 讀」的票面要求。

-- ---------------------------------------------------------------------------
-- 1. 兩支核心 helper：只讀旗標，PK 查詢，STABLE SECURITY DEFINER（比照本 schema
-- 既有 private.* 慣例，20260822120200_rls_policies.sql 檔頭的理由同樣適用：避免
-- RLS 遞迴、search_path 收斂）
-- ---------------------------------------------------------------------------

create or replace function private.caller_is_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1 from public.profiles p
     where p.id = auth.uid() and p.suspended_at is not null
  );
$$;

comment on function private.caller_is_active() is
  'LS-179：auth.uid() 未停權（或未登入、或 profile 尚未建立——這兩種情況本來就會
  被各自既有的「未登入」檢查擋下，這裡不重複判斷，回傳 true 讓後面的檢查接手）。
  PK 查詢（profiles.id），不需要額外索引。';

create or replace function private.family_is_active(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1 from public.families f
     where f.id = p_family_id and f.suspended_at is not null
  );
$$;

comment on function private.family_is_active(uuid) is
  'LS-179：指定家庭未停權（或家庭不存在——同樣留給既有的「找不到」檢查處理）。
  PK 查詢（families.id），不需要額外索引。';

create or replace function private.registrations_open()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select a.registrations_open from public.app_settings a where a.id = true),
    true
  );
$$;

comment on function private.registrations_open() is
  'LS-179（PLAN §10-A(3)）：目前是否開放新註冊（自建新家庭這一步，見
  private.enforce_registrations_open()）。coalesce 到 true 是防禦性寫法——這張表
  一定有那一列（本檔的 INSERT 種好），fail-open 只是避免萬一那一列不見時整個
  app 連家庭都建不了，不是預期路徑。';

-- caller_is_active()／family_is_active(uuid)：直接被 families_select／
-- content_reports_select／join_requests_select 三條 policy 引用（第 3 段，
-- R2 merge-review m1／m2），在 authenticated 角色底下求值，兩支都需要明確
-- grant——registrations_open() 只從 enforce_registrations_open() trigger
-- 內部呼叫（以 postgres 身分執行，物件擁有者對自己的物件恆有權限，
-- REVOKE ... FROM PUBLIC 影響不到擁有者），不需要對 authenticated 另外開放。
revoke execute on function private.caller_is_active() from public, anon;
grant execute on function private.caller_is_active() to authenticated;
revoke execute on function private.family_is_active(uuid) from public, anon;
grant execute on function private.family_is_active(uuid) to authenticated;
revoke execute on function private.registrations_open() from public, anon;

-- ---------------------------------------------------------------------------
-- 2. 收斂既有四支「我的家庭集合」函式（20260822120200_rls_policies.sql）——
-- 這是本檔對 SELECT 與 Storage 生效的唯一入口，cascade 到十幾張表的 _select
-- policy 與大部分直接寫入 policy，見檔頭「設計總覽」機制 1。
--
-- 為什麼直接 CREATE OR REPLACE 而不是另開新函式：這四支已經是每一條 policy 的
-- 判斷主體，改判斷式本身而不是疊加一層新函式，才不會讓「我到底屬於哪些家庭」
-- 這件事有兩份互相獨立、可能漂移的定義。B4（migration-breaking-check）會把這
-- 判成 BREAKING——既有呼叫端的行為確實變了（多了停權排除），PR body 見
-- `BREAKING:` 行。
--
-- 效能：每支函式原本就是「以 auth.uid() 查 family_members，回傳我所屬的家庭
-- id 集合」，這個集合的大小＝一個人的家庭數量（Phase 1 恆為 0 或 1，Phase 3
-- 之後也預期是個位數），不是内容表的列數。caller_is_active() 是每次呼叫一次
-- （不隨列數變化），family_is_active(m.family_id) 對這個小集合逐列呼叫一次，
-- 兩者都是 PK 查詢，總成本可忽略；`family_id in (select private.family_ids())`
-- 這種外層引用的形狀完全沒變，50_rls_plan_no_percall_subquery.sql 驗證的
-- 「整條查詢只算一次、不是逐列 correlated subquery」不受影響——family_ids()
-- 内部多算了什麼跟它對外層而言是不是一次性子查詢是兩件事。
-- ---------------------------------------------------------------------------

create or replace function private.family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid()
     and private.caller_is_active()
     and private.family_is_active(m.family_id);
$$;

create or replace function private.owned_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid() and m.role = 'owner'
     and private.caller_is_active()
     and private.family_is_active(m.family_id);
$$;

create or replace function private.contributor_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid() and m.role in ('owner', 'member')
     and private.caller_is_active()
     and private.family_is_active(m.family_id);
$$;

create or replace function private.uploadable_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.family_id from public.family_members m
   where m.user_id = auth.uid()
     and (m.role = 'owner' or (m.role = 'member' and m.can_upload))
     and private.caller_is_active()
     and private.family_is_active(m.family_id);
$$;

-- peer_profile_ids()：改寫成直接複用 family_ids()（已經內含兩種停權排除），取代
-- 原本自己重新 join family_members 一次的寫法——不是順手重構，是本票需要的行為：
-- 自己（`select auth.uid()`）永遠保留在聯集第一段、不受任何停權影響（被停權的
-- 人仍然「看得到自己」，只是看不到同家庭其他人，見下方），第二段換成
-- family_ids() 之後，我目前所屬且未停權的家庭裡的成員才會出現；我被停權時
-- family_ids() 是空集合，第二段整個消失，只剩下自己一筆——這正是票面「該 user
-- 對所有家庭資料的讀取一律拒絕」在 profiles 這張表上該有的效果（我自己的
-- profile 不算「別人家的家庭資料」，見第 3 段的範圍說明）。
create or replace function private.peer_profile_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid()
  union
  select m.user_id from public.family_members m
   where m.family_id in (select private.family_ids());
$$;

-- ---------------------------------------------------------------------------
-- 3.（範圍決策，Rule 1：明講、不悄悄略過）profiles 表本身刻意不掛任何停權判斷
--
-- `profiles_select`／`profiles_insert`／`profiles_update` 三條 policy
-- （20260822120200_rls_policies.sql）維持原樣：`profiles_select` 透過上面已改寫
-- 的 peer_profile_ids() 自動獲得「看不到同家庭其他人」的效果，但**看得到自己**；
-- `profiles_update`（`id = auth.uid()`）完全不動，被停權的使用者仍然能改自己的
-- 顯示名稱／頭像。
--
-- 理由：profiles 是帳號本體（`auth.users` 的公開側資料），不是 PLAN §5 定義的
-- 「家庭資料」（沒有 family_id、不屬於任何一個家庭）。票面文字是「該 user 對
-- **家庭資料**的讀寫一律拒絕」，逐字對照不涵蓋帳號自己的基本資料。連坐停用
-- 使用者查看／編輯自己帳號本身的能力，會讓 app 對一個已登入但被停權的人整個
-- 打不開（連「我的帳號」畫面都進不去），不是票面要的效果，也不是「營運防線」
-- 這個目的需要的手段——真正的防線是他碰不到任何家庭資料，不是他的帳號本身
-- 消失。若日後 QA／使用者認為連自己的 profile 也該鎖，屬於獨立的產品決策，
-- 請另開票，不在本票默默擴大範圍。
-- ---------------------------------------------------------------------------

-- families_select 的 created_by 分支需要單獨補 caller_is_active()／
-- family_is_active(id)：這個分支是 20260822120200_rls_policies.sql 為了
-- `insert ... returning` 那個時序洞開的後門（成員列由 AFTER INSERT trigger
-- 產生，RETURNING 投影發生在 trigger 之前，那個瞬間 family_ids() 還看不到這筆
-- 家庭），不經過 family_ids()，本檔的排除對它沒有作用——一個曾經建立過家庭、
-- 後來離開的使用者，即使被停權，仍然能透過這個分支永久看到那個家庭的名稱。
-- R2（merge-review R1 m2）：原本只加了 caller_is_active()，漏了
-- family_is_active(id)——家庭本身被停權時，建立者（即使本人未被個別停權）仍
-- 透過這個分支看得到 1 列，含 suspended_at／storage_quota_bytes 等欄位，違反
-- 「家庭停權→該家庭全部成員（建立者也是成員）一律拒絕」。兩個條件都要。
alter policy families_select on public.families
  using (
    id in (select private.family_ids())
    or (
      created_by = (select auth.uid())
      and private.caller_is_active()
      and private.family_is_active(id)
    )
  );

-- ---------------------------------------------------------------------------
-- R2（merge-review R1 m1）：content_reports_select／join_requests_select 的
-- 「自己那一支」分支同樣不經過任何一支集合函式（`reporter_id = auth.uid()`／
-- `applicant_id = auth.uid()`，跟上面 families_select 的 created_by 分支是
-- 同一種形狀），票面原文是「全部 policy」都要有停權判斷，這兩條之前漏了。
-- 「owner 那一支」（`family_id in (select private.owned_family_ids())`）已經
-- 走 owned_family_ids()，本檔第 2 段已收斂，不必再動。
-- ---------------------------------------------------------------------------
alter policy content_reports_select on public.content_reports
  using (
    (
      reporter_id = (select auth.uid())
      and private.caller_is_active()
      and private.family_is_active(family_id)
    )
    or family_id in (select private.owned_family_ids())
  );

alter policy join_requests_select on public.join_requests
  using (
    (
      applicant_id = (select auth.uid())
      and private.caller_is_active()
      and private.family_is_active(family_id)
    )
    or family_id in (select private.owned_family_ids())
  );

-- ---------------------------------------------------------------------------
-- 4. 共用寫入 guard：private.enforce_not_suspended()
--
-- 見檔頭「設計總覽」機制 2。掛在全部帶 family_id 欄位、authenticated 有寫入路徑
-- （直接或透過 RPC）的內容表，BEFORE INSERT OR UPDATE OR DELETE FOR EACH ROW。
--
-- 比照 private.enforce_account_not_deletion_requested()（LS-151）的既有慣例：
-- `auth.uid()` 為 NULL（沒有 JWT 的呼叫，例如 service_role 內部流程、測試 fixture
-- 以 postgres 身分直接寫入）時整段檢查跳過——這些表本來就各自有 RLS policy／
-- grant 擋未登入者，這裡只多加一層「已登入但被停權」的檢查，不取代、也不放寬
-- 既有的權限檢查，日後任何以 service_role 執行、需要處理已停權使用者資料的
-- 維運流程（例如帳號真正被刪除時的資料清理）不會被這支 trigger 意外擋下。
--
-- DELETE 沒有 NEW，用 tg_op 分流取 OLD 或 NEW 的 family_id；不修改列本身，
-- 通過檢查就原樣 return（INSERT/UPDATE 用 new，DELETE 用 old）。
--
-- R2（merge-review R1 MAJOR-2）：`delete_my_account()` 內部對
-- `family_members`／`diaries`／`albums`／`comments`／`media` 的寫入（見
-- 20260904070941_delete_account_media.sql）全部會落在這支 trigger 上，停權
-- （使用者或家庭）因此連帶把 app 內帳號刪除的唯一入口鎖死——App Store
-- Guideline 5.1.1(v)／PLAN §9-A2 的硬規定是「app 內刪除帳號」必須恆可用，不能
-- 因為帳號被停權就失效（甚至更需要能刪，那正是被停權的人最可能想做的事）。
-- 修法：`private.deletion_bypass_active()` 讀一個交易級（`is_local = true`）
-- GUC，見下方函式與 `delete_my_account()` 第 8 段的呼叫處。
-- ---------------------------------------------------------------------------

-- private.deletion_bypass_active()：純讀 GUC，不碰任何資料庫物件，不需要
-- SECURITY DEFINER／search_path 收斂（比照 20260823030000_storage_policies.sql
-- 的 private.is_media_object_path() 同型理由——沒有任何需要提權或防
-- search_path 挾持的動作）。
--
-- **為什麼 client 造不出這個逃生口（三層，任一層都足夠，寫在這裡集中說明，
-- 呼叫端 delete_my_account() 與 105_ 測試都引用這段）**：
--   1. 這個 GUC 名稱與值只由 `delete_my_account()` 這一支函式內部設定
--      （見該函式），沒有任何 public 函式把它參數化開放給呼叫端指定。
--   2. `pg_catalog.set_config` 本身不在 PostgREST 曝露的 schema 清單裡
--      （`supabase/config.toml`：`[api] schemas = ["public", "graphql_public"]`），
--      client 沒有任何 REST／RPC 路徑能自己呼叫它——`public` schema 裡也沒有
--      任何函式包裝、轉發這個呼叫。
--   3. 即使假設性地能呼叫，`is_local = true` 讓這個值只在**設定當下的那個
--      交易**內可見，隨交易結束（COMMIT／ROLLBACK）自動消失——PostgREST 一個
--      HTTP request 對應一個交易（這是整個 Supabase RLS／JWT-per-request 模型
--      本來就依賴的基礎假設，不是本票新引入的信任），這個值不會跨到「呼叫端
--      自己另外發出的下一個 request」。`delete_my_account()` 內部從設定這個
--      GUC 到函式結束之間的所有寫入，都在**同一個**交易裡，這正是唯一需要它
--      生效的範圍。
create or replace function private.deletion_bypass_active()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('ls179.account_deletion', true), '') = 'on';
$$;

create or replace function private.enforce_not_suspended()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_family_id uuid;
begin
  if private.deletion_bypass_active() then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if v_uid is not null then
    if not private.caller_is_active() then
      raise exception '這個帳號已被暫停使用，請聯絡我們' using errcode = 'LS052';
    end if;

    v_family_id := case when tg_op = 'DELETE' then old.family_id else new.family_id end;
    if v_family_id is not null and not private.family_is_active(v_family_id) then
      raise exception '這個家庭已被暫停使用，請聯絡我們' using errcode = 'LS053';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_not_suspended() from public, anon;

comment on function private.enforce_not_suspended() is
  'LS-179：掛在全部帶 family_id 的內容表的 BEFORE INSERT/UPDATE/DELETE，不論寫入
  路徑是直接 PostgREST 呼叫還是包在 SECURITY DEFINER RPC 裡都會觸發（trigger 不受
  SECURITY DEFINER 影響，只有 RLS policy 才會被繞過，比照
  private.enforce_account_not_deletion_requested()，LS-151）。auth.uid() 為 NULL
  時整段跳過（service_role／系統呼叫）。';

create trigger family_members_not_suspended
  before insert or update or delete on public.family_members
  for each row execute function private.enforce_not_suspended();

create trigger invites_not_suspended
  before insert or update or delete on public.invites
  for each row execute function private.enforce_not_suspended();

create trigger children_not_suspended
  before insert or update or delete on public.children
  for each row execute function private.enforce_not_suspended();

create trigger media_not_suspended
  before insert or update or delete on public.media
  for each row execute function private.enforce_not_suspended();

create trigger albums_not_suspended
  before insert or update or delete on public.albums
  for each row execute function private.enforce_not_suspended();

create trigger album_media_not_suspended
  before insert or update or delete on public.album_media
  for each row execute function private.enforce_not_suspended();

create trigger diaries_not_suspended
  before insert or update or delete on public.diaries
  for each row execute function private.enforce_not_suspended();

create trigger diary_media_not_suspended
  before insert or update or delete on public.diary_media
  for each row execute function private.enforce_not_suspended();

create trigger diary_children_not_suspended
  before insert or update or delete on public.diary_children
  for each row execute function private.enforce_not_suspended();

create trigger album_children_not_suspended
  before insert or update or delete on public.album_children
  for each row execute function private.enforce_not_suspended();

create trigger comments_not_suspended
  before insert or update or delete on public.comments
  for each row execute function private.enforce_not_suspended();

create trigger reactions_not_suspended
  before insert or update or delete on public.reactions
  for each row execute function private.enforce_not_suspended();

create trigger content_reports_not_suspended
  before insert or update or delete on public.content_reports
  for each row execute function private.enforce_not_suspended();

create trigger blocked_users_not_suspended
  before insert or update or delete on public.blocked_users
  for each row execute function private.enforce_not_suspended();

create trigger join_requests_not_suspended
  before insert or update or delete on public.join_requests
  for each row execute function private.enforce_not_suspended();

-- ---------------------------------------------------------------------------
-- 5. families 表：兩支獨立的 BEFORE INSERT trigger
--
-- families 沒有 family_id 欄位（它自己就是那個「家庭」），不能套用上面共用的
-- enforce_not_suspended()（NEW.family_id 在這張表上不存在，掛上去會在真正寫入時
-- 才炸出 "record new has no field family_id" 的 runtime 錯誤）。UPDATE／DELETE
-- 不需要另外處理：families_update 的 USING／WITH CHECK 都經過 owned_family_ids()
-- （第 2 段已收斂），families 沒有 DELETE policy，兩者都已經被機制 1 蓋到；只有
-- INSERT（自建新家庭）需要獨立的 trigger 補上機制 2 該給的自訂錯誤碼。
--
-- 兩支各自獨立（各自對應一個票面項目、各自可能各自演化），不合併成一支：
-- LS052（呼叫者停權）與 LS054（暫停開放新註冊）是兩個完全不相關的拒絕理由，
-- 合併會讓其中一支未來改動時得小心不要動到另一支的判斷。
--
-- 「無邀請碼自建家庭路徑」＝這張表的直接 INSERT（docs/API.md §3 families：
-- `insert into families (name, created_by)`，本 repo 沒有 create_family() 這支
-- RPC，讀過 migrations 確認過，不是漏找）。「憑邀請碼加入」（request_join／
-- approve_join）完全不碰這張表，不受這裡任何一支 trigger 影響，符合票面「既有
-- 成員登入、既有家庭加入不受影響」。
-- ---------------------------------------------------------------------------

create or replace function private.enforce_caller_not_suspended_for_families()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null and not private.caller_is_active() then
    raise exception '這個帳號已被暫停使用，請聯絡我們' using errcode = 'LS052';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_caller_not_suspended_for_families() from public, anon;

create trigger families_caller_not_suspended
  before insert on public.families
  for each row execute function private.enforce_caller_not_suspended_for_families();

create or replace function private.enforce_registrations_open()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.registrations_open() then
    raise exception '目前暫停開放新註冊，請稍後再試' using errcode = 'LS054';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_registrations_open() from public, anon;

create trigger families_registrations_open
  before insert on public.families
  for each row execute function private.enforce_registrations_open();

-- 補充（範圍決策）：device_tokens 不掛任何 trigger。票面只要求
-- notification_recipients() 排除停權者的裝置（下一段），device_tokens 本身既
-- 不屬於任何家庭（沒有 family_id）、註冊／更新自己的裝置 token 也不會讓被停權者
-- 拿到任何家庭資料——它純粹決定「這支裝置以後收不收得到推播」，而推播的收件人
-- 判定已經在 notification_recipients() 排除了停權者，兩層一起看已經沒有洞。
-- 連坐擋掉 register_device_token() 對停權者沒有額外的防護效果，只會讓他換裝置
-- 登入時卡在一個跟停權本身無關的技術限制上，故不列入本票範圍。

-- ---------------------------------------------------------------------------
-- 6. 三支唯讀 SECURITY DEFINER RPC：沒有寫入、又繞過 RLS 讀，機制 1／2 都碰不到，
-- 逐支補明確檢查（票面「既有 RPC 入口一律先檢查」）
-- ---------------------------------------------------------------------------

-- list_join_requests()：原本的授權檢查是手動 join family_members（family_id=
-- r.family_id and user_id=auth.uid() and role='owner'）——這就是 owned_family_ids()
-- 的定義，改成直接呼叫該函式，跟本檔第 2 段的排除自動同步，不必在這裡重複一次
-- 停權判斷（也避免兩份「我擁有哪些家庭」的定義各自漂移）。
create or replace function public.list_join_requests()
returns table (
  request_id uuid,
  family_id uuid,
  applicant_id uuid,
  display_name text,
  avatar_url text,
  role text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.family_id, r.applicant_id, p.display_name, p.avatar_url,
         i.role::text, r.created_at
    from public.join_requests r
    join public.invites i on i.id = r.invite_id
    join public.profiles p on p.id = r.applicant_id
   where r.status = 'pending'
     and r.family_id in (select private.owned_family_ids())
   order by r.created_at, r.id;
$$;

-- CREATE OR REPLACE 對不變的簽章本來就會保留既有 ACL（Postgres 文件明載），這裡
-- 仍明寫一次——本檔的保證要由本檔自己給，不建立在「另一個 migration 剛好也做了
-- 這件事」上（比照 20260904080802_finalize_account_deletion_media.sql 同樣情境
-- 的既有慣例）。
revoke execute on function public.list_join_requests() from public, anon;
grant execute on function public.list_join_requests() to authenticated;

-- get_my_join_request()：純資訊性的「我在等什麼」查詢，沒有副作用。停權時直接
-- 讓集合變空（0 列＝空結果，這支函式自己既有的慣例，見檔頭原註解），不特地為了
-- 這一支把 `language sql` 換成 plpgsql 只為了 RAISE 一個自訂碼——換語言的成本
-- 不值得，語意上跟「你其他家庭資料一律看不到」一致即可。
create or replace function public.get_my_join_request()
returns table (
  request_id uuid,
  family_id uuid,
  family_name text,
  status text,
  created_at timestamptz,
  resolved_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.family_id, f.name, r.status::text, r.created_at, r.resolved_at
    from public.join_requests r
    join public.families f on f.id = r.family_id
   where r.applicant_id = auth.uid()
     and private.caller_is_active()
   order by (r.status = 'pending') desc, r.created_at desc, r.id desc
   limit 1;
$$;

revoke execute on function public.get_my_join_request() from public, anon;
grant execute on function public.get_my_join_request() to authenticated;

-- list_comments()：既有的 plpgsql 函式本來就在 v_uid 檢查之後緊接著做手動的
-- 家庭成員檢查，這裡在那之前插入停權檢查，回自訂碼——跟其餘每一支 RPC 把
-- 「未登入」放在最前面的既有排列方式一致（帳號／家庭狀態檢查先於業務授權檢查）。
create or replace function public.list_comments(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_limit integer default 20
)
returns table (
  id uuid,
  author_id uuid,
  author_display_name text,
  author_avatar_url text,
  body text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
begin
  if v_uid is null then
    raise exception '未登入，無法讀取留言' using errcode = '42501';
  end if;

  if not private.caller_is_active() then
    raise exception '這個帳號已被暫停使用，請聯絡我們' using errcode = 'LS052';
  end if;

  if not private.family_is_active(p_family_id) then
    raise exception '這個家庭已被暫停使用，請聯絡我們' using errcode = 'LS053';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能讀取留言' using errcode = '42501';
  end if;

  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception '游標參數必須同時提供或同時省略（p_cursor_created_at／p_cursor_id）'
      using errcode = 'LS022';
  end if;

  if p_cursor_created_at is null then
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and not exists (
               select 1 from private.blocked_pairs() bp
                where bp.family_id = cm.family_id
                  and bp.blocked_id = cm.author_id
             )
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  else
    return query
      select c.id, c.author_id, pr.display_name, pr.avatar_url, c.body, c.created_at
        from (
          select cm.id, cm.author_id, cm.body, cm.created_at
            from public.comments cm
           where cm.family_id = p_family_id
             and cm.target_type = v_target_type
             and cm.target_id = p_target_id
             and cm.deleted_at is null
             and (cm.created_at, cm.id) < (p_cursor_created_at, p_cursor_id)
             and not exists (
               select 1 from private.blocked_pairs() bp
                where bp.family_id = cm.family_id
                  and bp.blocked_id = cm.author_id
             )
           order by cm.created_at desc, cm.id desc
           limit v_limit
        ) c
        left join public.profiles pr on pr.id = c.author_id
       order by c.created_at desc, c.id desc;
  end if;
end;
$$;

revoke execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  from public, anon;
grant execute on function
  public.list_comments(uuid, text, uuid, timestamptz, uuid, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. notification_recipients()：排除停權使用者（票面 1，LS-172 對象判定加一條）
--
-- 只排除「使用者本人被停權」，不額外排除「所屬家庭被停權」——家庭一旦被停權，
-- 該家庭的所有寫入（comments／media／diaries…）都已經被第 4 段的 trigger 擋下，
-- 不會再產生新的 notification_events，這裡不需要為了一個不會發生的路徑重複判斷
-- 一次（範圍對齊票面原文「排除停權使用者」，不含家庭）。
-- ---------------------------------------------------------------------------

create or replace function public.notification_recipients(p_event_ids uuid[])
returns table (
  event_id uuid,
  user_id uuid,
  token text,
  platform public.device_platform
)
language sql
stable
security definer
set search_path = ''
as $$
  select ne.id as event_id, fm.user_id, dt.token, dt.platform
    from public.notification_events ne
    join public.family_members fm on fm.family_id = ne.family_id
    join public.profiles pr on pr.id = fm.user_id
    join public.device_tokens dt on dt.user_id = fm.user_id
   where ne.id = any(p_event_ids)
     and fm.user_id is distinct from ne.actor_id
     and pr.suspended_at is null
     and not exists (
       select 1
         from public.blocked_users bu
        where bu.family_id = ne.family_id
          and bu.blocker_id = fm.user_id
          and bu.blocked_id = ne.actor_id
     );
$$;

revoke execute on function public.notification_recipients(uuid[]) from public, anon;

-- ---------------------------------------------------------------------------
-- 8.（R2，MAJOR-2）delete_my_account()：停權（使用者或家庭）不得連帶封死
--
-- 整支函式本體逐字複製自 `20260904070941_delete_account_media.sql`（該檔已併入
-- origin/development，append-only、不可回頭改，見 migration-immutable-check.sh）
-- 目前的定義——**只加一行**：`perform private.enforce_deletion_bypass();`，
-- 緊接在「未登入」檢查之後、任何實際寫入之前。這支函式的鎖序（family_members
-- 先、families 後、跨家庭 family_id 遞增序）是三輪 review 才訂出來的極細緻
-- 不變量（見該檔檔頭「修訂歷史」），本次**不改動任何一行既有邏輯、不改動任何
-- 語句順序**，只在最前面插入這一行——它不取任何鎖、不查任何表，純粹是設一個
-- 交易級 GUC，對後面的鎖序分析沒有影響。
-- ---------------------------------------------------------------------------

create or replace function private.enforce_deletion_bypass()
returns void
language sql
as $$
  select set_config('ls179.account_deletion', 'on', true);
$$;

comment on function private.enforce_deletion_bypass() is
  'LS-179 R2（MAJOR-2）：只被 public.delete_my_account() 呼叫。設一個交易級
  （is_local=true）GUC，讓 private.enforce_not_suspended() 對這次呼叫觸發的
  全部寫入放行，理由與「client 造不出這個逃生口」的三層論證見
  private.deletion_bypass_active() 的函式註解。包成函式（而不是讓
  delete_my_account() 直接 `perform set_config(...)`）只是為了讓呼叫處那一行
  自解釋，沒有其他理由。';

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
