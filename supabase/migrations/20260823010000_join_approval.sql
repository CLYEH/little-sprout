-- LS-33（LS-18 後端）— 邀請碼、加入申請與管理員審核
--
-- 使用者核定的 spec：「邀請碼＋管理員審核」。加入家庭的完整路徑是
--   owner 產碼（create_invite）→ 申請人輸入碼（request_join）
--   → 家庭若開啟審核：建立 pending 申請，owner 核准／拒絕（approve_join／reject_join）
--   → 家庭若關閉審核：直接寫入 family_members
-- 申請人可自行撤回（withdraw_join）。
--
-- 這個 migration 全部是新增（新型別／新欄位／新表／新 RPC／收緊既有 policy 的 WITH CHECK），
-- 沒有任何刪除物件、清空資料或改欄位型別的語句，可以在既有雲端專案上直接套用。
--
-- 上面這句話刻意不寫出那幾個關鍵字的英文原文：CI 的破壞性 migration 偵測器是對
-- migration diff 的新增行做關鍵字比對，不會分辨那一行是 SQL 還是註解——
-- 「本檔沒有清空資料的語句」這種宣告本身就含有它要抓的字，會被判定成破壞性變更
-- （PR #36 實測撞到：唯一命中的就是本檔原本的這行註解）。
--
-- 三條設計上的硬決定，先寫在這裡，細節在各段落：
--   1. **成員寫入的唯一路徑是 SECURITY DEFINER RPC**：family_members_insert policy 收斂成
--      WITH CHECK (false) 並收回 authenticated 的 INSERT grant（LS-6 review m2 的技術債）。
--      owner 不能再繞過邀請直接把任何 user_id 塞進自家名單。
--   2. **used_count 在「申請成立」時就消耗**，不是核准時。核准時才扣的話，一支邀請碼可以被
--      無限多人同時申請占用（申請不需要任何人同意），owner 面對一長串待審清單而額度形同虛設。
--      代價：拒絕／撤回不退還次數（退還會讓「申請→撤回」變成免費的無限迴圈，且退還本身
--      又是一次併發加減）。owner 需要更多名額時重新產碼即可。
--   3. **邀請碼的正規化形式由 create_invite 決定**：8 碼、大寫、字元集 23456789ABCDEFGHJKLMNPQRSTUVWXYZ
--      （拿掉 0/O/1/I 這兩組長輩手抄與口述最容易錯的字）。request_join 會把輸入去掉非英數並轉大寫
--      之後「完全比對」invites.code，所以直接以 SQL 寫進 invites 的非正規化 code（例如帶連字號或
--      小寫）將無法被兌換——日後若要手工建立長期邀請碼（PLAN §9-C：審核用 demo 帳號），
--      請照這個字元集產生，或直接呼叫 create_invite。

-- ---------------------------------------------------------------------------
-- 1. 申請狀態列舉
--
-- withdrawn 與 rejected 分開存：對 UI 是兩種完全不同的敘述（「你撤回了」vs「對方拒絕了」），
-- 合併成一個 rejected 會讓申請人看到自己沒做過的事。
-- ---------------------------------------------------------------------------
create type public.join_request_status as enum ('pending', 'approved', 'rejected', 'withdrawn');

-- ---------------------------------------------------------------------------
-- 2. families.require_approval —— 家庭層級的審核開關
--
-- 預設 true（嚴格側）：這是私密家庭相簿，「拿到碼就直接進來」必須是家庭主動選擇的結果，
-- 不是預設值。既有家庭在這個 migration 之後一律變成需要審核，不會有人因為升級而被動放寬。
--
-- 權限：column-level grant 只加 require_approval（沿用 init_schema 的慣例——families 的
-- UPDATE grant 是逐欄列舉的，storage_quota_bytes／storage_used_bytes 這條 §10-A 成本防線
-- 靠的就是「沒有被列舉」）。加上既有的 families_update policy（USING/WITH CHECK 都要求
-- owned_family_ids），實際可改這一欄的只有該家庭的 owner。
-- ---------------------------------------------------------------------------
alter table public.families add column require_approval boolean not null default true;

comment on column public.families.require_approval is
  'true＝以邀請碼申請加入需 owner 核准（預設）；false＝驗碼通過即直接成為成員。只有 owner 改得動（column grant + families_update policy）。';

grant update (require_approval) on public.families to authenticated;

-- ---------------------------------------------------------------------------
-- 3. invites 的複合唯一鍵
--
-- 純粹是為了讓 join_requests 能以 (family_id, invite_id) 複合外鍵綁定同家庭的邀請碼，
-- 沿用 init_schema 既有的作法（albums_child_same_family_fkey 等）：跨 family 的關聯
-- 不是「看不到」而是「建不起來」。新增 UNIQUE 不影響既有資料（id 本來就是 PK，
-- (family_id, id) 必然唯一），也不是破壞性變更。
-- ---------------------------------------------------------------------------
alter table public.invites add constraint invites_family_id_id_key unique (family_id, id);

-- ---------------------------------------------------------------------------
-- 4. join_requests —— 加入申請
--
-- applicant_id / resolved_by 指向 public.profiles 而不是 auth.users：整個 schema 的
-- 使用者外鍵一律指向 profiles（family_members.user_id、families.created_by、media.uploaded_by
-- 都是），而且核准時要寫入的 family_members.user_id 本來就要求 profiles 存在——
-- 若允許沒有 profile 的帳號送出申請，錯誤只會延後到 owner 按下「核准」的那一刻才爆，
-- 由申請人自己承擔的失敗變成 owner 看不懂的失敗。寧可在申請當下就擋。
-- （profiles.id 本身 references auth.users on delete cascade，所以刪帳號一樣會清掉申請。）
-- ---------------------------------------------------------------------------
create table public.join_requests (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  invite_id uuid not null,
  applicant_id uuid not null references public.profiles (id) on delete cascade,
  status public.join_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  -- resolved_* 三者同進退：pending 時皆為 NULL，一旦離開 pending 就一定填上
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null,
  -- 邀請碼必須屬於同一個家庭，否則「用 B 家的碼申請進 A 家」在資料層是可表達的
  constraint join_requests_invite_same_family_fkey foreign key (family_id, invite_id)
    references public.invites (family_id, id) on delete cascade
);

comment on table public.join_requests is
  '以邀請碼提出的加入申請。只有 SECURITY DEFINER RPC 寫得動（request_join／approve_join／reject_join／withdraw_join）；authenticated 只有 SELECT。';

-- 同一個申請人對同一個家庭同時只能有一筆 pending：
-- 部分索引而不是普通 UNIQUE——被拒絕／撤回之後必須能重新申請（換一支新碼、或請 owner 再看一次）。
-- 這是 DB 層的保證，不只是 request_join 裡那句 EXISTS 檢查：兩個併發的申請若用的是
-- 同一個家庭的「不同」邀請碼，兩邊鎖的是不同的 invites 列，EXISTS 檢查會雙雙放行，
-- 只有這個索引攔得住（supabase/tests/80_join_approval.sql 直接對這個索引做行為斷言）。
create unique index join_requests_pending_unique
  on public.join_requests (family_id, applicant_id)
  where status = 'pending';

-- owner 的待審清單：where family_id = ? and status = 'pending' order by created_at
create index join_requests_family_status_idx
  on public.join_requests (family_id, status, created_at desc);

-- 申請人的「我的申請」清單，同時也是 RLS policy 那一支 applicant_id = auth.uid() 的存取路徑
create index join_requests_applicant_idx
  on public.join_requests (applicant_id, created_at desc);

-- 複合外鍵的子表側索引：owner 撤銷（DELETE）一支邀請碼時，cascade 要在這張表上找子列。
-- 沒有這個索引就是每撤銷一次碼掃一次全表，而這張表是全站共用（不是每家一張）。
create index join_requests_invite_idx on public.join_requests (family_id, invite_id);

-- ---------------------------------------------------------------------------
-- 5. join_requests 的 RLS
--
-- 只有 SELECT policy，而且 grant 也只給 SELECT：寫入路徑全部走 definer RPC。
-- 沒有 INSERT/UPDATE/DELETE policy ＝ RLS 預設拒絕，就算日後有人不小心補了 grant，
-- 也還是進不來（兩層都要壞掉才會破）。
-- ---------------------------------------------------------------------------
alter table public.join_requests enable row level security;

grant select on public.join_requests to authenticated;

-- auth.uid() 一律包成 (select auth.uid())：STABLE 不是 IMMUTABLE，直接寫在 qual 裡會逐列呼叫
-- （同 rls_policies.sql 的註記）。
create policy join_requests_select on public.join_requests for select to authenticated
  using (
    applicant_id = (select auth.uid())
    or family_id in (select private.owned_family_ids())
  );

-- ---------------------------------------------------------------------------
-- 6. family_members_insert 收斂（LS-6 review m2 的技術債）
--
-- 原本：`with check (family_id in (select private.owned_family_ids()))`
--       ＝ owner 可以直接把任何 user_id 塞進自家成員名單，完全不必經過邀請碼。
--       那條 policy 當時的存在理由是「現階段沒有 RPC，關掉會讓家庭加不了人」——
--       RPC 現在有了，理由消失。
--
-- 收斂成兩層，兩層都要在：
--   a) policy WITH CHECK (false)：任何 authenticated 的 INSERT 都不通過。
--      用 ALTER POLICY 而不是 DROP + CREATE，policy 這個物件與它的名字留著，
--      日後 `\d public.family_members` 看到的是「明確關閉」而不是「不見了」。
--   b) 收回 INSERT 的 table grant：policy 是可能被下一個 migration 改鬆的，
--      grant 是另一份獨立的資料。init_schema 的註解對 families 的成本防線講過同一件事：
--      少一層 grant 就少一種被 policy 疏漏波及的可能。
--
-- 不受影響的路徑（都是以表擁有者 postgres 身分執行，本來就不經過 RLS 與 authenticated 的 grant）：
--   - private.add_creator_as_owner()：建立家庭時把 created_by 寫成第一位 owner（§9-C5，
--     全新使用者必須能自己建立家庭）。這條路徑有專門的回歸測試，不是靠推論。
--   - 本檔案的 request_join()／approve_join()。
-- ---------------------------------------------------------------------------
alter policy family_members_insert on public.family_members with check (false);

revoke insert on public.family_members from authenticated;

-- ---------------------------------------------------------------------------
-- 7. RPC
--
-- 全部 SECURITY DEFINER + `set search_path = ''` + 全名限定（definer 的標準防護，
-- 避免被呼叫端的 search_path 挾持）。授權採 LS-15 定下的 per-RPC 顯式 grant 慣例：
-- 逐支 revoke public/anon 再 grant authenticated。
--
-- 錯誤碼（沿用 LS001／LS002 的自訂 SQLSTATE 慣例，UI 要能分文案）：
--   LS010 邀請碼不存在      LS011 已過期        LS012 次數用罄
--   LS013 你已經是成員      LS014 已有待審申請  LS015 申請不存在或已被處理
--   LS016 產碼連續撞碼      42501 未登入／權限不足   22023 參數不合理
-- ---------------------------------------------------------------------------

-- create_invite：只有 owner 能為自己的家庭產碼。
--
-- 參數帶 p_family_id 是必要的（ticket 的簡寫簽名沒有寫）：PLAN §1 明講「一個帳號可屬於
-- 多個家庭」，沒有 family_id 就無法決定要對哪一家產碼。
--
-- p_role 用 text 而不是 public.family_role：沿用 register_device_token(p_platform text) 的
-- 慣例，在函式內部轉型；不合法的角色字串會得到 22P02。
create or replace function public.create_invite(
  p_family_id uuid,
  p_role text,
  p_expires_at timestamptz,
  p_max_uses integer
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- 32 個字元剛好是 2 的冪：亂數位元組 mod 32 沒有取模偏差（256 = 8 × 32），
  -- 8 碼 ＝ 40 bits 的熵，且亂數來源是 gen_random_uuid()（pg_strong_random，
  -- 不是 random()）——邀請碼可被預測等於陌生人進家庭。
  c_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_uid uuid := auth.uid();
  v_code text;
  v_bytes bytea;
  k int;
  attempt int;
begin
  if v_uid is null then
    raise exception '未登入，無法建立邀請碼' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid and m.role = 'owner'
  ) then
    raise exception '只有該家庭的 owner 能建立邀請碼' using errcode = '42501';
  end if;

  -- 已經過期的碼建得起來但兌換不了，是純粹的支援案件（多半是時區算錯）。當場擋掉。
  if p_expires_at is null or p_expires_at <= now() then
    raise exception '邀請碼的到期時間必須在未來' using errcode = '22023';
  end if;

  -- p_max_uses <= 0 由 invites 的 CHECK 擋（invites_max_uses_check），不在這裡重複判斷。
  for attempt in 1..5 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for k in 0..7 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, k) % 32) + 1, 1);
    end loop;

    begin
      insert into public.invites (family_id, code, role, created_by, max_uses, expires_at)
      values (p_family_id, v_code, p_role::public.family_role, v_uid, p_max_uses, p_expires_at);
      return v_code;
    exception when unique_violation then
      -- 撞碼重抽。40 bits 的撞碼機率實務上不會發生，但「不會發生」不能寫成無限迴圈：
      -- 真的連撞 5 次代表亂數來源壞了，要 fail loud 而不是把 CPU 燒完。
      null;
    end;
  end loop;

  raise exception '邀請碼產生連續撞碼，請重試' using errcode = 'LS016';
end;
$$;

revoke execute on function public.create_invite(uuid, text, timestamptz, integer) from public, anon;
grant execute on function public.create_invite(uuid, text, timestamptz, integer) to authenticated;

-- request_join：驗碼 → 依家庭設定建立 pending 申請或直接入家。
--
-- 回傳 (status, request_id, family_id)：
--   status = 'pending' → request_id 是新建的申請 id，UI 顯示「等待核准」
--   status = 'joined'  → request_id 為 NULL，UI 直接進家庭（family_id 就是要導向的家）
-- 審核關閉時不留 join_requests 列：那一列會是一筆沒有審核者的 approved 紀錄，
-- 對 owner 的待審清單與申請人的申請紀錄都只是雜訊。
--
-- 併發正確性（本函式最重要的部分）：
--   `for no key update` 鎖住 invites 那一列，讓「同一支邀請碼」的所有申請在最後一個名額上排隊。
--   READ COMMITTED 下，SELECT ... FOR NO KEY UPDATE 在等到鎖之後會重讀該列的最新版本
--   （EvalPlanQual）——這是 Postgres 的機械事實，也是「後到的那個一定看得到 used_count 已被加過」
--   的唯一依據。沒有這把鎖，兩個人同時搶最後一個名額會雙雙通過 used_count 檢查，
--   最後靠 invites_uses_within_max 這條 CHECK 才擋下第二個人——結果雖然還是只有一個人成立，
--   但輸的那個拿到的是 23514（DB 約束違反）而不是 LS012，UI 沒辦法對他說「這支碼用完了」。
--   併發時序測試見 supabase/tests/concurrency/join_race_*.sql。
--
--   用 FOR NO KEY UPDATE 而不是 FOR UPDATE：沿用 LS-6 enforce_family_has_owner 的鎖策略。
--   FOR UPDATE 與子表 FK 檢查取的 FOR KEY SHARE 互斥，而 join_requests 正是 invites 的子表
--   （複合外鍵），「A 鎖碼、B 插申請」的兩個交易會多一條死鎖邊；FOR NO KEY UPDATE 不與
--   FOR KEY SHARE 衝突，但仍與自身互斥，序列化效果不變。
--
--   刻意「不」序列化的一件事：require_approval 是不加鎖讀的。owner 在某人按下加入的
--   同一瞬間切換審核開關時，該次申請會落在切換前或切換後，兩種結果都正確（要嘛進待審
--   清單、要嘛直接入家），沒有任何不變量會因此被破壞。為了這個沒有後果的時序去鎖住
--   families 那一列，只會把「同一個家庭的所有加入動作」互相卡住。
--
-- 註：函式的 OUT 欄位（status／request_id／family_id）在 plpgsql 裡是變數，
-- 所以本函式內所有 SQL 的欄位引用一律加表別名限定，不要寫裸欄位名。
create or replace function public.request_join(p_code text)
returns table (status text, request_id uuid, family_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_invite public.invites%rowtype;
  v_require_approval boolean;
  v_request_id uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法申請加入家庭' using errcode = '42501';
  end if;

  -- 正規化：手抄的碼會有小寫、空白、連字號。比對的一律是 create_invite 產出的形式。
  v_code := regexp_replace(upper(coalesce(p_code, '')), '[^0-9A-Z]', '', 'g');

  select i.* into v_invite
    from public.invites i
   where i.code = v_code
     for no key update;

  -- 三種錯誤分開回報：UI 要能分別說「碼打錯了」「這支碼過期了」「這支碼被用完了」，
  -- 混成一個「無效的邀請碼」會讓使用者反覆重打一個永遠不會成功的碼。
  if not found then
    raise exception '邀請碼不存在' using errcode = 'LS010';
  end if;

  if v_invite.expires_at <= now() then
    raise exception '邀請碼已過期' using errcode = 'LS011';
  end if;

  if v_invite.used_count >= v_invite.max_uses then
    raise exception '邀請碼的使用次數已用完' using errcode = 'LS012';
  end if;

  -- 已是成員就不再消耗次數（誤點自己家的碼不該扣掉一個名額）
  if exists (
    select 1 from public.family_members m
     where m.family_id = v_invite.family_id and m.user_id = v_uid
  ) then
    raise exception '你已經是這個家庭的成員' using errcode = 'LS013';
  end if;

  if exists (
    select 1 from public.join_requests r
     where r.family_id = v_invite.family_id
       and r.applicant_id = v_uid
       and r.status = 'pending'
  ) then
    raise exception '你對這個家庭已經有一筆待審核的申請' using errcode = 'LS014';
  end if;

  select f.require_approval into v_require_approval
    from public.families f where f.id = v_invite.family_id;

  if v_require_approval then
    begin
      insert into public.join_requests (family_id, invite_id, applicant_id)
      values (v_invite.family_id, v_invite.id, v_uid)
      returning join_requests.id into v_request_id;
    exception when unique_violation then
      -- 同一人用同一家庭的「不同」邀請碼併發申請時，兩邊鎖的是不同的 invites 列，
      -- 上面那句 EXISTS 會雙雙放行，只有 join_requests_pending_unique 擋得住。
      -- 這裡把它翻譯回 LS014，UI 不必認得 23505。
      raise exception '你對這個家庭已經有一筆待審核的申請' using errcode = 'LS014';
    end;
  else
    -- 審核關閉：直接入家，角色取自邀請碼。
    -- can_upload 用資料表預設（true）——viewer 能不能上傳由 private.uploadable_family_ids()
    -- 依 role 判斷，與這個欄位無關。
    begin
      insert into public.family_members (family_id, user_id, role)
      values (v_invite.family_id, v_uid, v_invite.role);
    exception when unique_violation then
      -- 與上面 pending 那一支同一個理由：同一人用同一家庭的「不同」邀請碼併發申請時，
      -- 兩邊鎖的是不同的 invites 列，上面那句「已是成員」的 EXISTS 會雙雙放行，
      -- 最後由 family_members 的主鍵擋下。翻譯回 LS013，UI 不必認得 23505。
      raise exception '你已經是這個家庭的成員' using errcode = 'LS013';
    end;
  end if;

  -- 消耗次數：寫成 used_count = used_count + 1（讀改寫成 v_used + 1 會在沒有鎖的情況下
  -- 變成 lost update）。invites_uses_within_max 這條 CHECK 是最後一道機械防線。
  update public.invites i
     set used_count = i.used_count + 1
   where i.id = v_invite.id;

  return query select
    case when v_require_approval then 'pending' else 'joined' end,
    v_request_id,
    v_invite.family_id;
end;
$$;

revoke execute on function public.request_join(text) from public, anon;
grant execute on function public.request_join(text) to authenticated;

-- approve_join：只有該家庭的 owner。寫入 family_members（role 取自邀請碼）＋ 標記申請已核准。
--
-- 併發（approve 與 reject 同時打同一筆申請）：`for update` 鎖住申請列，後到的那個交易
-- 會等；等到之後 Postgres 重讀最新列版本（qual 是 id = p_request_id，不受狀態變更影響），
-- 於是讀到的是已被前一個交易改成 approved/rejected 的狀態，被下面那句 status 檢查擋成 LS015。
-- 沒有這把鎖，兩邊都會讀到 pending 而各自放行：申請被標成 rejected，成員卻已經寫進去了——
-- 「拒絕後無殘留權限」這條驗收條件會在這個時序下破掉。
-- 時序測試見 supabase/tests/concurrency/approve_reject_race_*.sql。
--
-- 授權檢查刻意排在狀態檢查之前：不是該家 owner 的人，不管申請是什麼狀態一律拿到 42501，
-- 不會從錯誤碼的差別推敲出某個 request id 存不存在。
create or replace function public.approve_join(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.join_requests%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法審核加入申請' using errcode = '42501';
  end if;

  select r.* into v_req from public.join_requests r
   where r.id = p_request_id
     for update;

  if not found then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = v_req.family_id and m.user_id = v_uid and m.role = 'owner'
  ) then
    raise exception '只有該家庭的 owner 能審核加入申請' using errcode = '42501';
  end if;

  if v_req.status <> 'pending' then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  -- 角色取自邀請碼。invite 一定還在（join_requests 對 invites 的複合外鍵是 on delete cascade，
  -- 碼被撤銷時這筆申請會一起消失），所以這個純量子查詢不會是 NULL；真的是 NULL 的話
  -- role 的 NOT NULL 會擋下（23502），不會安靜地寫入一個沒有角色的成員。
  -- 已經是成員時（例如在待審期間用另一支碼直接入家）不重複寫入，也不覆蓋既有角色——
  -- owner 想要的結果「這個人在家裡」已經成立。
  insert into public.family_members (family_id, user_id, role)
  values (
    v_req.family_id,
    v_req.applicant_id,
    (select i.role from public.invites i where i.id = v_req.invite_id)
  )
  on conflict (family_id, user_id) do nothing;

  update public.join_requests r
     set status = 'approved', resolved_at = now(), resolved_by = v_uid
   where r.id = p_request_id;
end;
$$;

revoke execute on function public.approve_join(uuid) from public, anon;
grant execute on function public.approve_join(uuid) to authenticated;

-- reject_join：只有該家庭的 owner。只改狀態，不寫任何成員資料。
-- 鎖與檢查順序同 approve_join（兩支對同一筆申請併發時只有一個生效）。
create or replace function public.reject_join(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.join_requests%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法審核加入申請' using errcode = '42501';
  end if;

  select r.* into v_req from public.join_requests r
   where r.id = p_request_id
     for update;

  if not found then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = v_req.family_id and m.user_id = v_uid and m.role = 'owner'
  ) then
    raise exception '只有該家庭的 owner 能審核加入申請' using errcode = '42501';
  end if;

  if v_req.status <> 'pending' then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  update public.join_requests r
     set status = 'rejected', resolved_at = now(), resolved_by = v_uid
   where r.id = p_request_id;
end;
$$;

revoke execute on function public.reject_join(uuid) from public, anon;
grant execute on function public.reject_join(uuid) to authenticated;

-- withdraw_join：只有申請人本人、只有 pending 可撤。
-- resolved_by 記的是撤回者本人——這一欄的語意是「誰讓這筆申請離開 pending」，不是「誰核准」。
-- 撤回不退還 used_count（見檔頭決定 2）。
create or replace function public.withdraw_join(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req public.join_requests%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法撤回申請' using errcode = '42501';
  end if;

  select r.* into v_req from public.join_requests r
   where r.id = p_request_id
     for update;

  if not found then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  if v_req.applicant_id <> v_uid then
    raise exception '只有申請人本人能撤回申請' using errcode = '42501';
  end if;

  if v_req.status <> 'pending' then
    raise exception '申請不存在或已被處理' using errcode = 'LS015';
  end if;

  update public.join_requests r
     set status = 'withdrawn', resolved_at = now(), resolved_by = v_uid
   where r.id = p_request_id;
end;
$$;

revoke execute on function public.withdraw_join(uuid) from public, anon;
grant execute on function public.withdraw_join(uuid) to authenticated;
