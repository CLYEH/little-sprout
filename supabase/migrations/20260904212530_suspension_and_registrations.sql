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
-- DEFINER helper，票面規定），不查 `suspended_reason`（那一欄只給 Dashboard 人工
-- 看，不進任何判斷式）。
--
-- 範圍刻意排除的兩塊（都寫在對應段落，這裡先列清單，避免看起來像遺漏）：
--   - `profiles` 表本身（自己的 SELECT／UPDATE）不掛任何停權判斷——見第 3 段。
--   - `device_tokens` 不掛 trigger——見第 5 段結尾。
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
  add column suspended_at timestamptz,
  add column suspended_reason text;

comment on column public.profiles.suspended_at is
  'LS-179（PLAN §10-B）：Dashboard 手動 UPDATE 這一欄即生效，不改程式碼。非 NULL
  時，這個使用者對「所有」家庭資料（不限於他目前所屬的家庭）的 RLS 讀寫與既有
  RPC 入口一律拒絕，見 private.caller_is_active()／private.enforce_not_suspended()。
  不影響其他使用者。解除＝設回 NULL。';

comment on column public.profiles.suspended_reason is
  '只給 Dashboard 人工看的停權原因，不進任何權限判斷式，client 也讀不到（沒有
  SELECT grant，見下方）。';

alter table public.families
  add column suspended_at timestamptz,
  add column suspended_reason text;

comment on column public.families.suspended_at is
  'LS-179（PLAN §10-B）：Dashboard 手動 UPDATE 這一欄即生效。非 NULL 時，這個家庭
  的全部成員（不分角色）對這個家庭的資料一律拒絕讀寫；成員對「其他」家庭不受
  影響（Phase 3 多家庭前置）。見 private.family_is_active()／
  private.enforce_not_suspended()。';

comment on column public.families.suspended_reason is
  '只給 Dashboard 人工看的停權原因，不進任何權限判斷式。';

-- client 讀不到這四欄（不在下面重新開放的欄位級 grant 清單裡）：停權原因是稽核
-- 用途，停權旗標本身也不該讓被停權者自己用 API 探知「我被停了」（他只會從每一次
-- 操作失敗的 LS052／LS053 間接得知）。原本 `authenticated` 對 profiles／families
-- 就已經是逐欄 grant（見 20260822120000_init_schema.sql／20260903084231_
-- delete_account.sql），新增欄位不主動出現在任何既有 grant 清單裡，天生就是
-- 不可讀不可寫，不需要額外一句 REVOKE。

create table public.app_settings (
  -- 單列表：id 恆為 true，CHECK 保證永遠只有一列，不需要另外的唯一性判斷。
  id boolean primary key default true check (id),
  registrations_open boolean not null default true,
  updated_at timestamptz not null default now()
);

comment on table public.app_settings is
  'LS-179（PLAN §10-A(3)）：全域營運開關，目前只有 registrations_open 一欄。單列表
  ——Dashboard 手動 UPDATE 這一欄（`where id = true`）即生效，不改程式碼。只有
  service_role 能寫（RLS 沒有任何 INSERT/UPDATE/DELETE policy，且 authenticated
  沒有對應的 table grant，見下方）；authenticated 只能透過
  private.registrations_open() 讀單一布林值，不開放整表 SELECT 給 client（沒有
  理由讓 client 看到 updated_at 之類的欄位）。';

insert into public.app_settings (id, registrations_open) values (true, true);

alter table public.app_settings enable row level security;

-- 沒有 grant 給 authenticated：這張表完全不對 client 開放直接讀寫，唯一的讀取
-- 路徑是下面的 private.registrations_open()（SECURITY DEFINER，繞過 RLS）。
-- 因此這裡也不需要任何 policy——RLS 啟用但沒有 policy＝對 authenticated/anon
-- 全部拒絕，符合「只有 service_role 可寫，client 只能透過 helper 讀」的票面要求。

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

-- caller_is_active() 直接被 families_select policy 引用（第 4 段），在 authenticated
-- 角色底下求值，需要明確 grant——family_is_active()／registrations_open() 只從
-- 其他 SECURITY DEFINER 函式／trigger 內部呼叫（以 postgres 身分執行，物件擁有者
-- 對自己的物件恆有權限，REVOKE ... FROM PUBLIC 影響不到擁有者），不需要對
-- authenticated 另外開放。
revoke execute on function private.caller_is_active() from public, anon;
grant execute on function private.caller_is_active() to authenticated;
revoke execute on function private.family_is_active(uuid) from public, anon;
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

-- families_select 的 created_by 分支需要單獨補 caller_is_active()：這個分支是
-- 20260822120200_rls_policies.sql 為了 `insert ... returning` 那個時序洞開的
-- 後門（成員列由 AFTER INSERT trigger 產生，RETURNING 投影發生在 trigger 之前，
-- 那個瞬間 family_ids() 還看不到這筆家庭），不經過 family_ids()，本檔的排除
-- 對它沒有作用——一個曾經建立過家庭、後來離開的使用者，即使被停權，仍然能透過
-- 這個分支永久看到那個家庭的名稱。加這一句排除掉。
alter policy families_select on public.families
  using (
    id in (select private.family_ids())
    or (created_by = (select auth.uid()) and private.caller_is_active())
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
-- ---------------------------------------------------------------------------

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
