-- LS-151（LS-24 拆票之二）— Edge Function delete-account 的資料面支援：
--   1. profiles.deletion_requested_at 開放 service_role SELECT（Edge Function 用
--      service_role 檢查這一欄，見 docs/API.md §「Edge Functions」）。
--   2.（第一道防線，R2 新增）public.finalize_account_deletion(uuid)：Edge Function
--      在呼叫 service_role 執行 `delete from auth.users` 之前，先以 service_role
--      重跑一次資料面清理（票文選項 (b)），不論下面第 3 點的擋寫有沒有漏洞，這一步
--      保證呼叫者在被真正刪除之前一定沒有任何一列 family_members，見下方第 3 段。
--   3.（第二道防線，縱深防禦）過渡期擋寫：deletion_requested_at 非 NULL 時，擋下
--      create_family／approve_join／owner 交接／request_join／上傳／建立內容各類
--      寫入，讓過渡期使用者的體驗上是「立刻生效」（進不去建立家庭、等待審核等畫面），
--      不是「保證刪除成功」唯一依靠的機制——見下方第 4 段。
--
-- 背景（LS-143 merge-review R1 i1，`d9cce6a4`，實測確認）：delete_my_account() 回傳
-- 成功之後、Edge Function 真正刪掉 auth.users 之前，這個帳號仍是完全可用的登入身份
-- ——deletion_requested_at 目前不被任何既有 RLS policy 或 grant 讀取。若使用者在這個
-- 窗口內又成為某個家庭的唯一 owner，Edge Function 呼叫 service_role 執行
-- `delete from auth.users` 時，cascade 到 family_members 的刪除會被既有的
-- private.enforce_family_has_owner() trigger 擋下（LS001），該次刪除會失敗
-- （docs/API.md §4 delete_my_account 已明文；本 migration 是那句話承諾的落地）。
--
-- ---------------------------------------------------------------------------
-- R2（2026-09-04，merge-review R1 `b1eb4e1d` B1／M1，`d09e6e53` 裁定訂正）：
-- 為什麼從「只做 (a)」改成「(b) 為主、(a) 為輔」的兩道防線
--
-- R1 版本只做過渡期擋寫（(a)），檔頭曾經宣稱「delete_my_account() 成功回傳的那一刻，
-- 呼叫者在 family_members 裡已經沒有任何一列……過渡期唯一能讓他又成為唯一 owner 的
-- 路徑只有重新取得一列 family_members……把這張表的 INSERT 直接擋掉，這個情境就從
-- 資料面直接消失」——這句話被 reviewer 實測推翻：
--   B1：family_members 的擋寫只掛在 BEFORE INSERT，UPDATE 路徑完全沒擋。健康的
--       owner 用既有的 owner 交接路徑（直接 `update family_members set role='owner'`，
--       見 20260903084231_delete_account.sql 檔頭引用的既有路徑）一樣能把一個
--       deletion_requested_at 非 NULL 的人升成唯一 owner；且 INSERT 的 guard 若只查
--       auth.uid()（操作者），也擋不住「過渡期使用者自己 request_join → 健康 owner
--       approve_join」這條路（核准者的 auth.uid() 不是過渡期使用者）。
--   M1：guard 的 exists() 查詢是快照讀、不取任何鎖，`delete_my_account()` 標記
--       deletion_requested_at 的那個交易與並行的 INSERT／UPDATE 之間存在一個 READ
--       COMMITTED 窗口，雙連線實測會被穿過。
-- 這兩條合起來代表：**只靠擋寫，「過渡期又成為唯一 owner」不會真的從資料面消失**，
-- 只是變得更難發生；而且一旦發生，`deletion_requested_at` 沒有任何路徑能自行清除
-- （authenticated 對這一欄沒有 UPDATE 權限），使用者會永久卡在「刪不掉、也用不了」
-- 的狀態。票文驗收條件要的是「刪除仍能成功完成」，不是「觸發機率降低」。
--
-- 所以改採票文選項 (b) 當**第一道、真正的防線**：public.finalize_account_deletion()
-- 只能由 service_role 執行，Edge Function 在 `deleteAuthUser()` 之前呼叫它，重跑一次
-- 資料面清理——不論過渡期擋寫有沒有漏洞，這一步都會把 p_user 從所有家庭清乾淨，讓
-- 後面的 `delete from auth.users` 一定不會撞見 LS001（細節見下方第 3 段）。下面第 4
-- 段的過渡期擋寫**保留為第二道防線**：B1 的 UPDATE 路徑（guard 改查 NEW.user_id）
-- 與 request_join 的縱深防禦都補上，不是白做——它讓大多數情況下過渡期使用者連 UI
-- 上的「建立新家庭」「等待審核」畫面都進不去。
-- ---------------------------------------------------------------------------
--
-- 為什麼第二道防線不能只靠 RLS policy：family_members 唯一的寫入路徑是兩支
-- SECURITY DEFINER 函式（private.add_creator_as_owner()、public.approve_join()），
-- 兩者都以表擁有者（postgres）身分執行、天生繞過 RLS——family_members_insert policy
-- 早在 LS-33 就已經是 `with check (false)`（20260823010000_join_approval.sql），對
-- 這兩支函式完全無感，這正是它們必須存在的理由。真正能擋住 SECURITY DEFINER 函式
-- 寫入的只有 BEFORE trigger（trigger 不受 RLS bypass 影響，任何身分的寫入都會先
-- 經過它）。
--
-- 擋寫範圍（票文「create_family、approve_join、上傳、建立內容」逐項對應；不是只擋
-- 最小必要的 family_members，是把票文點名的四類寫入行為都擋掉，R2 再加 UPDATE 路徑
-- 與 join_requests 縱深防禦）：
--   families        → create_family（直接 INSERT，任何登入者建立家庭的唯一路徑）
--   family_members  → 建立新家庭的自動 owner INSERT（private.add_creator_as_owner）
--                      ＋ approve_join（核准加入）＋（R2）owner 交接等 UPDATE OF
--                      role, user_id（見下方獨立的專用 guard，B1）
--   media           → 上傳（直接 INSERT，有上傳權者）
--   diaries         → 建立內容：create_diary_entry
--   albums          → 建立內容：直接 INSERT（owner／member）
--   children        → 建立內容：create_child
--   comments        → 建立內容：create_comment
--   join_requests   →（R2 新增，縱深防禦）request_join——B1 攻擊路徑的第一步就是
--                      過渡期使用者自己呼叫 request_join，把它擋在申請這一步，不用
--                      等到某天有人 approve 時才被 family_members 的 guard 擋下、
--                      留下一筆永遠不會被核准的 pending 申請
-- 刻意不擋（規格分歧與取捨，供之後改動的人對照）：invites（create_invite）、
-- reactions（toggle_reaction）、device_tokens（register_device_token）、
-- diary_children／album_children（標記，不是新內容本體）——這幾張表的寫入不會讓
-- 呼叫者取得任何一列 family_members，不構成 R1 i1 指出的「又成為唯一 owner」風險。
--
-- 錯誤碼 LS051（延續 LS050，同一批 LS-24 拆票，避開同時在飛的 LS-153——LS-153
-- 的 20260903110908_purge_expired.sql 沒有使用任何新的 LSnnn 自訂碼，不會撞號）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. service_role 讀 profiles.deletion_requested_at（Edge Function 用）
--
-- 比照 notification_events 的既有教訓（20260825020000_comments_reactions_notifications.sql
-- 「service_role 也要明確 grant」）：public schema 新 grant／既有表對 service_role 的
-- 存取不是平台預設會給，必須自己明確授權。profiles 從第一支 migration 起就沒有對
-- service_role 下過任何 grant（table owner 是 postgres，service_role 是不同角色）。
-- 只開 SELECT：Edge Function 只需要讀這一欄判斷是否放行，不需要寫 profiles
-- （auth.users 被 admin API 刪除後，profiles 隨既有的 on delete cascade 自動消失，
-- 不需要 Edge Function 自己 UPDATE／DELETE 這張表）。
--
-- R2（merge-review R1 i1）收斂成欄位級：只開 id（EF 用 `.eq("id", uid)` 過濾，
-- PostgREST／grant 系統要求 WHERE 子句引用的欄位也要有 SELECT 權限）與
-- deletion_requested_at（實際要讀的值）——不開放整表 SELECT，service_role 本來
-- 就是伺服器側全權金鑰、開整表也不構成新破口，但欄位級是更小的權限面。
-- ---------------------------------------------------------------------------
grant select (id, deletion_requested_at) on public.profiles to service_role;

-- ---------------------------------------------------------------------------
-- 2. 過渡期擋寫的共用 guard 函式（第二道防線，六張「自著內容」表用）
--
-- SECURITY DEFINER＋search_path 收斂：比照本 schema 所有 private 函式的既有慣例
-- （60_default_privileges.sql 第 9 段），且這裡確實需要讀 public.profiles（trigger
-- 若以 invoker 身分執行，讀 profiles 本身沒問題——authenticated 對 profiles 有整表
-- SELECT grant，見 20260822120000_init_schema.sql——但 definer 是本 schema 一貫寫法，
-- 不另立例外）。auth.uid() 為 NULL（沒有 JWT claims 的 session，例如 pg_cron／測試
-- 用 postgres 身分直接 INSERT 造 fixture）時直接放行——這不是「未登入者可以寫」的
-- 破口：這些表原本就各自有 RLS policy／grant 擋未登入者，這裡的 guard 只多加一層
-- 「已登入但正在刪帳號過渡期」的檢查，不取代、也不放寬既有的權限檢查。
-- 不需要登記進 60_default_privileges.sql §2 的 v_allow_fns：這是純內部用的 trigger
-- 函式，不對外開放 EXECUTE，本來就會被該段的通掃覆蓋（不開放給 authenticated／anon）。
--
-- 這六張表（families／media／diaries／albums／children／comments）檢查 auth.uid()
-- 是安全的：唯一的寫入路徑都是「自著內容」——建立者／上傳者／作者本來就必然是
-- auth.uid() 自己（RPC 或 RLS policy 已經保證這一點），不存在「操作者是別人、被
-- 寫入的是過渡期使用者」這種 B1 指出的錯位。family_members／join_requests 不是
-- 這種形狀（approve_join 的操作者是 owner、被寫入的是申請人），需要各自獨立的
-- guard，見下方 2b／2c。
-- ---------------------------------------------------------------------------
create or replace function private.enforce_account_not_deletion_requested()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is not null and exists (
    select 1 from public.profiles where id = v_uid and deletion_requested_at is not null
  ) then
    raise exception
      '帳號已請求刪除（過渡期間），無法再建立新資料——請等待帳號刪除完成'
      using errcode = 'LS051';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_account_not_deletion_requested() from public, anon;

comment on function private.enforce_account_not_deletion_requested() is
  'LS-151：deletion_requested_at 非 NULL 時擋下 INSERT（LS051）。掛在
  families／media／diaries／albums／children／comments 六張「自著內容」表的
  BEFORE INSERT，讓過渡期使用者無法再建立新資料。這是第二道防線（縱深防禦）；
  family_members／join_requests 各自有專用 guard（見
  private.enforce_family_member_write_not_deletion_requested／
  enforce_join_request_not_deletion_requested），檢查的是「被寫入的人」而不是
  auth.uid()（merge-review R1 B1）。真正保證「刪除一定成功」的第一道防線是
  public.finalize_account_deletion()（見下方）。';

create trigger families_deletion_guard
  before insert on public.families
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger media_deletion_guard
  before insert on public.media
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger diaries_deletion_guard
  before insert on public.diaries
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger albums_deletion_guard
  before insert on public.albums
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger children_deletion_guard
  before insert on public.children
  for each row execute function private.enforce_account_not_deletion_requested();

create trigger comments_deletion_guard
  before insert on public.comments
  for each row execute function private.enforce_account_not_deletion_requested();

-- ---------------------------------------------------------------------------
-- 2b.（R2，merge-review R1 B1）family_members 專用 guard——改查「被寫入列」的
-- user_id，不是 auth.uid()
--
-- B1 實測到的攻擊路徑：deletion_requested_at 非 NULL 的使用者 U 自己呼叫
-- request_join()，另一個健康的 owner 呼叫 approve_join() 核准——INSERT 的
-- auth.uid() 是核准者、不是 U，R1 版本查 auth.uid() 的 guard 因此放行，U 拿到一列
-- family_members（用 owner 邀請碼甚至直接是 owner）。UPDATE 路徑同理：健康 owner
-- 用既有的 owner 交接路徑 `update family_members set role='owner' where user_id=U`
-- 把 U 升成 owner，auth.uid() 是操作者、不是 U，R1 版本完全沒擋（只掛在
-- BEFORE INSERT）。
--
-- 改查 NEW.user_id 之後，不論是誰執行這個 INSERT／UPDATE，只要「被寫進去（或被
-- 改角色）的那個人」是過渡期使用者，一律擋下——防線與「操作者是誰」無關，只看
-- 「結果會不會讓過渡期使用者拿到／改變一列 family_members」，approve_join 的
-- 核准者身分、owner 交接的操作者身分都不影響判斷。
--
-- 這支必須維持 row-level（不能比照 minor-7 建議、像其餘六表改成 statement-level）：
-- 判斷條件現在依賴 NEW.user_id，跟被寫入的是哪一列有關，改成 statement-level＋
-- transition table 會失去這個資訊。只掛 INSERT 與 UPDATE OF role, user_id：
-- can_upload 的異動與這個不變量無關，不需要每次都多查一次 profiles。
-- ---------------------------------------------------------------------------
create or replace function private.enforce_family_member_write_not_deletion_requested()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is not null and exists (
    select 1 from public.profiles
     where id = new.user_id and deletion_requested_at is not null
  ) then
    raise exception
      '帳號已請求刪除（過渡期間），無法再取得或變更家庭成員身分——請等待帳號刪除完成'
      using errcode = 'LS051';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_family_member_write_not_deletion_requested() from public, anon;

comment on function private.enforce_family_member_write_not_deletion_requested() is
  'LS-151 R2（merge-review R1 B1）：deletion_requested_at 非 NULL 時擋下
  family_members 的 INSERT 與 UPDATE OF role, user_id（LS051）——檢查的是
  NEW.user_id（被寫入的人），不是 auth.uid()（操作者），關閉 approve_join／owner
  交接由「別人」把過渡期使用者寫進 family_members 的路徑。第二道防線；第一道、
  真正保證「刪除一定成功」的是 public.finalize_account_deletion()（見下方）。';

create trigger family_members_deletion_guard
  before insert or update of role, user_id on public.family_members
  for each row execute function private.enforce_family_member_write_not_deletion_requested();

-- ---------------------------------------------------------------------------
-- 2c.（R2，merge-review R1 B1 建議「縱深防禦」）join_requests 專用 guard
--
-- B1 攻擊路徑的第一步是過渡期使用者 U 自己呼叫 request_join()——join_requests 不在
-- R1 版本的擋寫範圍內（當時的理由：這張表本身的寫入不會讓 U 取得 family_members
-- 列，邏輯上仍然成立）。這裡補上不是因為漏洞出在這裡，是把攻擊路徑堵在最前面：
-- 過渡期使用者本來就不該再對任何家庭發起新的動作，讓 request_join 在申請這一步
-- 就失敗，比等到某天有人 approve 時才被上面 2b 擋下、留下一筆永遠不會被核准的
-- pending 申請，對使用者與 owner 都更清楚。
--
-- 檢查 NEW.applicant_id（不是 auth.uid()）：現有唯一的寫入路徑
-- （public.request_join()）兩者必然相等，這裡刻意寫成查被寫入欄位，跟 2b 用同一種
-- 「檢查結果、不檢查操作者」的原則，即使日後出現新的寫入路徑也不會因為改查
-- auth.uid() 而失守。
-- ---------------------------------------------------------------------------
create or replace function private.enforce_join_request_not_deletion_requested()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.applicant_id is not null and exists (
    select 1 from public.profiles
     where id = new.applicant_id and deletion_requested_at is not null
  ) then
    raise exception
      '帳號已請求刪除（過渡期間），無法再提出加入家庭的申請——請等待帳號刪除完成'
      using errcode = 'LS051';
  end if;
  return new;
end;
$$;

revoke execute on function private.enforce_join_request_not_deletion_requested() from public, anon;

comment on function private.enforce_join_request_not_deletion_requested() is
  'LS-151 R2：deletion_requested_at 非 NULL 時擋下 join_requests 的 INSERT
  （LS051），檢查 NEW.applicant_id（不是 auth.uid()）。縱深防禦，見 migration
  檔頭「R2」段落——不是 B1 的漏洞本身，是把攻擊路徑堵在申請這一步。';

create trigger join_requests_deletion_guard
  before insert on public.join_requests
  for each row execute function private.enforce_join_request_not_deletion_requested();

-- ---------------------------------------------------------------------------
-- 3.（R2，merge-review R1 B1／M1 裁定，第一道防線）
-- public.finalize_account_deletion(p_user uuid)：Edge Function 在
-- `deleteAuthUser()` 之前重跑一次資料面清理
--
-- 只有 service_role 能執行（revoke all from public/anon/authenticated 見下方）。
-- 語意比照 delete_my_account()（20260903084231_delete_account.sql）的「離開
-- 家庭」邏輯，但多一步：delete_my_account() 假設呼叫者不是任何家庭的「唯一
-- owner 且家庭還有其他成員」（那種情況在 RPC 那一層就已經被 LS050 拒絕、根本不會
-- 標記 deletion_requested_at）；這裡呼叫的時間點是「已經標記過、但過渡期內可能又
-- 透過 B1／M1 指出的路徑取得或維持了某個家庭的成員身分」，所以要能處理「唯一
-- owner」這個 delete_my_account() 不會留給它處理的情況——不是拒絕（沒有人能回應
-- 這個拒絕，帳號正在被刪除），是把 owner 身分轉移給家庭裡最早加入的其他成員
-- （沒有其他成員就整個家庭一併刪除，語意同 delete_my_account() 的「唯一成員」
-- 情況）。
--
-- 鎖策略（關 M1 的快照讀穿過窗口，票文 R2 裁定第 3 點；取鎖順序 R3 訂正，
-- merge-review R2 N1）：對每個候選家庭，**先**鎖住這個家庭目前所有的
-- family_members 列（FOR UPDATE），**再**鎖住 families 列（同樣 FOR UPDATE、不是
-- FOR NO KEY UPDATE——這是刻意的，要跟子表 INSERT 的 FK 檢查取的 FOR KEY SHARE
-- 互斥，20260903084231_delete_account.sql 檔頭「m1」段落已經記錄過同一個機制：
-- FOR UPDATE 與 FOR KEY SHARE 互斥，FOR NO KEY UPDATE 不會）。
--
-- 取鎖順序對齊既有的 private.enforce_family_has_owner()（20260822120100_triggers.sql
-- 的 family_members_owner_guard_delete／_update）：那顆既有 trigger 的鎖序永遠是
-- 「DML 先自然鎖住它正在改的 family_members 列 → AFTER STATEMENT trigger 才對
-- families 取 FOR NO KEY UPDATE」，任何直接 UPDATE／DELETE family_members 的
-- 路徑（owner 交接、離開家庭等）都遵循這個順序。R2 版本先鎖 families、再鎖
-- family_members，順序相反——merge-review R2 N1 雙連線實測到 40P01
-- deadlock detected：finalize 持有 families 的 FOR UPDATE、等待某個
-- family_members 列被另一個併發的 UPDATE 釋放；那個併發 UPDATE 已經持有那一列、
-- 其 AFTER trigger 正在等 finalize 持有的 families 鎖——循環等待。R3 把順序倒過來
-- 之後，任何走「trigger 順序」的併發操作與 finalize 之間**不會**形成鎖等待環：
-- 兩邊現在的鎖序都是 family_members 先、families 後，只會有其中一邊先取得、
-- 另一邊排隊等待，不會互等。
--
-- 這是本函式引入的新風險類型（不是 delete_my_account() 情況 2 那種既有性質）：
-- 情況 2 只鎖 families、從不先鎖 family_members，不存在順序倒置的可能；本函式
-- 因為要同時判斷「是否唯一 owner」而必須讀整個家庭的 family_members，才第一次
-- 讓兩張表的鎖序有機會跟既有 trigger 顛倒。修正後，剩下的只是「同一個家庭有
-- 併發成員異動」這種一般性的鎖等待（不是死鎖）——Postgres 自動偵測、單邊回滾、
-- 無資料損毀，重試必定收斂，client 端契約見 docs/API.md §10。
--
-- 升格再刪除的順序：唯一 owner 的情況下，**先** UPDATE 把候選成員升成 owner，
-- **再** DELETE p_user 自己那一列——兩個statement 邊界都至少有一位 owner，不會
-- 撞見既有的 private.enforce_family_has_owner()（同 delete_my_account() 的既有
-- owner 交接慣例）。候選成員取「最早加入」（family_members.created_at 升冪，
-- 同秒以 user_id 打破平手）：沒有更好的預設可言，選最早加入的人是最不武斷的規則。
--
-- family_id 遞增序處理候選家庭：與本 schema 其餘會鎖多個 families 列的函式
-- （delete_my_account() 情況 2、enforce_family_has_owner()）一致，避免多個家庭
-- 之間的取鎖順序不一致造成死鎖。
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
  --    失敗時（例如下面的鎖等待），這筆申請也已經不在，不會留下一筆申請人已標記
  --    刪除、卻還沒被 GoTrue 真正移除的過渡態殘留（R3 訂正：舊註解說「不清掉會
  --    變成永遠等不到人處理的申請」不成立，cascade 本來就會清，merge-review R2
  --    N4）。
  delete from public.join_requests where applicant_id = p_user and status = 'pending';

  -- 2. 逐一處理 p_user 目前所屬的每個家庭（鎖序見上方「鎖策略」段落：
  --    family_members 先、families 後，對齊既有 trigger）。
  for v_family_id in
    select fm.family_id from public.family_members fm
     where fm.user_id = p_user
     order by fm.family_id
  loop
    perform 1 from public.family_members fm2 where fm2.family_id = v_family_id for update;
    perform 1 from public.families f where f.id = v_family_id for update;

    -- 取鎖過程中 p_user 理論上不會被別的路徑移除（這是目前對 family_members 唯一
    -- 會這樣做的清理路徑，且此刻已持有鎖），但仍保守處理，避免下面誤判出多餘的
    -- 升格／刪除。
    if not exists (
      select 1 from public.family_members fm3
       where fm3.family_id = v_family_id and fm3.user_id = p_user
    ) then
      continue;
    end if;

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
  成員異動互為死鎖。';
