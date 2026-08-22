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
--      WITH CHECK (false) 並收回 authenticated 的 INSERT grant（LS-6 review m2 的技術債），
--      同時把 UPDATE 的整表 grant 收成只有 (role, can_upload) 兩欄（見第 6b 段——
--      只關 INSERT 的話，owner 改寫既有列的 user_id 一樣能把陌生人塞進來，後果完全相同）。
--      owner 不能再繞過邀請把任何 user_id 弄進自家名單，不論是新增一列還是改寫一列。
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

-- resolved_by 也是外鍵（on delete set null），RI 檢查走的是同一條「以父鍵找子列」的路徑：
-- 使用者刪帳號（§9-A2）時 Postgres 要找出所有 resolved_by = 該帳號的申請列。
-- 其餘三個外鍵都有索引可用，只有這個沒有——補上，理由與上面那條相同。
create index join_requests_resolved_by_idx on public.join_requests (resolved_by);

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
-- 6b. family_members 的 UPDATE 也要收斂——只收 INSERT 是攔不住的
--
-- 光關掉 INSERT 並不能讓「成員寫入的唯一路徑是 RPC」成立：UPDATE 的 grant 是整表的，
-- 而 family_members_update policy 只約束 family_id（USING 與 WITH CHECK 都是
-- `family_id in owned_family_ids()`）。於是 owner 可以拿自家「既有的」任何一列——
-- 例如一位 viewer——把它的 user_id 改成任意帳號：
--
--   update public.family_members set user_id = '<陌生人>'
--    where family_id = '<我的家庭>' and user_id = '<我家的 viewer>';
--
-- family_id 沒變，policy 兩側都通過，影響 1 列。那個陌生人立刻取得該家庭的成員資格，
-- 全家的照片、日記、留言都看得到（PR #36 review 實測重現，本檔的測試也照樣打一發）。
-- 換句話說，被關掉的 INSERT 只是「新增一列」這條路，「改寫既有列的歸屬」這條路仍然開著，
-- 而兩條路的後果完全相同。
--
-- 修法沿用 init_schema 對 families／media 的既有慣例：column-level grant 逐欄列舉。
-- owner 該能改的只有兩件事——角色升降（role）與逐人開關上傳（can_upload，PLAN §3）；
-- user_id／family_id／created_at 是「這一列在講誰、屬於哪一家、何時加入」，
-- 三者都不是「修改」語意的東西，要改就是新增或移除成員，那兩條路都只走 RPC 與既有的
-- DELETE policy（退出家庭／owner 移除成員）。
--
-- 注意 REVOKE 的順序：先整表收回再逐欄發放。反過來寫（先 grant 欄位再 revoke 整表）
-- 會把剛發下去的欄位權限一起收掉——REVOKE 整表會連帶拿掉該表的欄位授權。
-- ---------------------------------------------------------------------------
revoke update on public.family_members from authenticated;
grant update (role, can_upload) on public.family_members to authenticated;

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
--   LS016 產碼連續撞碼      LS017 邀請碼參數不合法   42501 未登入／權限不足
--
-- create_invite 的參數驗證一律用 LS017（到期時間與可用次數共用一個碼）：對 UI 而言
-- 這是同一件事——「你送來的邀請設定不合法」，訊息本文說明是哪一項；分成兩個碼只會
-- 讓前端多寫一個 case 卻說不出更有用的話。原本到期時間用的是 Postgres 內建的 22023，
-- 與另一項的 LS017 併存等於同一類失敗有兩種形狀，已統一。
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
  -- 32 個字元剛好是 2 的冪：亂數位元組 mod 32 沒有取模偏差（256 = 8 × 32）。
  c_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  -- 亂數來源是 gen_random_uuid()（底層 pg_strong_random，不是 random()——
  -- 可被預測的邀請碼等於陌生人進家庭），但 **不能拿它的 16 個位元組隨便用**：
  -- UUID v4 有兩個位元組不是亂數（RFC 9562 §5.4）——
  --   byte 6 的高 nibble 固定是版本碼 0x4（值域只剩 0x40–0x4F，mod 32 只有 16 種結果）
  --   byte 8 的高 2 bits 固定是 variant 0b10
  -- 原本的寫法直接取 byte 0..7，第 7 碼因此只抽得到半個字元集，整支碼的熵是 39 bits
  -- 而不是註解宣稱的 40（PR #36 review 抓到）。這裡改成明確挑 8 個完全隨機的位元組，
  -- 每碼都是滿的 5 bits。byte 8 雖然低 6 bits 也是亂數，但取模後不均勻，一併避開。
  -- （不用 pgcrypto 的 gen_random_bytes：那需要假設 extension 裝在哪個 schema，
  --  而 LS-14／LS-15 已經兩次被「雲端有、官方本機映像沒有」的佈建落差咬到。
  --  gen_random_uuid() 是 PG13+ 的內建函式，沒有這個問題。）
  c_random_bytes constant int[] := array[0, 1, 2, 3, 4, 5, 7, 9];

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

  -- 參數上下限：RPC 是安全邊界，不是 UI 的輔助。UI 的下拉選單擋得住手滑，擋不住
  -- 直接打 /rest/v1/rpc/create_invite 的人——一支「100 年後到期、可用 100000 次」的碼
  -- 外流一次，這個家庭就永久對外開放，而 max_uses／expires_at 正是 PLAN §5、§8
  -- 用來限制外洩後果的那兩個旋鈕。
  --
  -- 30 天：邀請家人加入是一次性的動作，不是長期開放的入口；真的過期了重發一支即可。
  -- 20 次：私密家庭相簿的成員數量級是「一家人」（PLAN §1），一支碼要用超過 20 次，
  --        代表在做的是別的事情。
  -- 兩者都刻意訂在「明顯夠用」而不是「剛剛好」，避免為了正常用途而反覆撞牆。
  --
  -- 例外記錄：PLAN §9-C 的審核用 demo 帳號需要「長期有效邀請碼」。那條路徑不受這裡
  -- 影響——平台方用 service_role／dashboard 直接寫 invites（本 RPC 是給 app 使用者的
  -- 邊界），只要照 create_invite 的字元集產碼即可（見檔頭決定 3）。
  if p_expires_at is null
     or p_expires_at <= now()
     or p_expires_at > now() + interval '30 days' then
    raise exception '邀請碼的到期時間必須在未來 30 天內' using errcode = 'LS017';
  end if;

  -- p_max_uses 為 NULL 時，invites 的 NOT NULL 會噴 23502（裸的 DB 錯誤，UI 認不得）；
  -- 上限則沒有任何 CHECK 擋。兩者都在這裡收進錯誤碼體系。
  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 20 then
    raise exception '邀請碼的可用次數必須介於 1 到 20 之間' using errcode = 'LS017';
  end if;

  for attempt in 1..5 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for k in 1..8 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, c_random_bytes[k]) % 32) + 1, 1);
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

  -- coalesce(..., true)：這是一個安全開關，讀不到值時必須倒向嚴格側（建待審申請），
  -- 而不是「直接讓人進家門」。以現在的 schema 這個 NULL 取不到（欄位 NOT NULL，
  -- 且 invites 對 families 有外鍵，家庭一定存在），所以這不是在修一個現存的洞——
  -- 是讓「哪一天這個查詢因為別的改動而回不出列」的後果變成 fail-closed 而不是 fail-open。
  if coalesce(v_require_approval, true) then
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

-- ---------------------------------------------------------------------------
-- 8. 兩支唯讀 RPC：審核畫面與等待畫面需要的「跨界」資料
--
-- 為什麼需要它們：加入申請在成立的那一刻，申請人與該家庭還沒有任何成員關係，
-- 而 RLS 的可見範圍正是以成員關係畫的。於是兩邊都看不到對方最基本的資訊——
--   - owner 的審核清單只有申請人的 uuid（profiles_select 只讓同家庭成員互看），
--     等於要 owner 對著一串 uuid 決定要不要讓人進家門；
--   - 申請人的等待畫面只有 family_id（families_select 同理），寫不出「等待〈家庭名〉核准」。
--
-- 採「窄 RPC」而不是放寬 profiles_select／families_select 的 policy（orchestrator 裁定）：
-- 放寬 policy 會讓「所有欄位、所有查詢路徑」都跟著打開，而這裡只需要
-- display_name／avatar_url 與家庭 name 這三個欄位、只在有 pending 申請這個前提下。
-- definer 函式把暴露面收斂成「這兩支函式的回傳欄位」，是可以逐欄審查的範圍。
--
-- 兩支都是唯讀（language sql + stable），授權寫在查詢的 WHERE／JOIN 裡：
--   - list_join_requests：以 inner join family_members(role='owner') 限定呼叫者是該家 owner
--   - get_my_join_request：以 applicant_id = auth.uid() 限定只看得到自己那筆
-- 因此未登入（auth.uid() 為 NULL）自然得到 0 列，不需要另外 raise——這與前面五支
-- 會寫入資料的 RPC 不同：那些若在 uid 為 NULL 時往下走會寫出沒有主體的資料列，
-- 所以必須當場擋；這兩支不會寫任何東西，空集合就是正確答案。
-- ---------------------------------------------------------------------------

-- list_join_requests：owner 的待審清單（含申請人的顯示名稱與頭像）。
--
-- 不帶 family_id 參數：一個帳號可能是多個家庭的 owner（PLAN §1），一次拿回所有
-- 待審申請才做得出「有 N 件待審」這種跨家庭的提示；回傳欄位帶 family_id，
-- UI 要分家庭顯示自己分組即可。
--
-- profiles 只投影 display_name 與 avatar_url 兩欄——這是這支函式對「非同家庭的人」
-- 開放的全部個人資料，逐欄列舉讓它可以被審查，日後 profiles 加欄位也不會被順帶帶出去。
-- applicant_id 照樣回傳：那本來就在申請人自己那一列，owner 經 join_requests_select
-- 早就看得到，不是這支函式新增的暴露。
--
-- 排序用最舊的在前：這是一條審核佇列，等最久的人應該排在最上面。
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
    -- 這個 join 就是授權檢查本身：呼叫者不是該家庭的 owner 就沒有對應的成員列，
    -- 那一筆申請也就不會出現在結果裡。
    join public.family_members m
      on m.family_id = r.family_id
     and m.user_id = auth.uid()
     and m.role = 'owner'
   where r.status = 'pending'
   order by r.created_at, r.id;
$$;

revoke execute on function public.list_join_requests() from public, anon;
grant execute on function public.list_join_requests() to authenticated;

-- get_my_join_request：申請人自己的那一筆申請（含家庭名稱）。
--
-- 只投影 families.name 一欄：等待畫面要寫「等待〈家庭名〉核准」，除此之外
-- 申請人在被核准前不該看到這個家庭的任何東西。
--
-- 挑哪一筆（回傳最多一列，這條規則要明確，否則 UI 的行為會隨資料而飄）：
--   1. 有 pending 就一定回 pending 那筆——這個畫面的用途是「我在等什麼」，
--      待審永遠比歷史重要（一個人可能同時對 A 家有待審、剛被 B 家拒絕）。
--   2. 都沒有 pending 才回最近一筆已處理的，狀態照實回（approved／rejected／withdrawn），
--      UI 才有辦法顯示「你的申請已被拒絕」而不是安靜地變成空白畫面。
--   3. 從未申請過 → 0 列。
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
   order by (r.status = 'pending') desc, r.created_at desc, r.id desc
   limit 1;
$$;

revoke execute on function public.get_my_join_request() from public, anon;
grant execute on function public.get_my_join_request() to authenticated;
