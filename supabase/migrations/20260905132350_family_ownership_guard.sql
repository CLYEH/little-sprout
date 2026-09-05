-- LS-206（LS-24 拆票）— 家庭成員管理守門：唯一 owner 且家庭仍有其他成員時不得退出
-- ／被移除（新錯誤碼 LS057，DETAIL 帶需先轉移提示）＋ transfer_ownership() RPC
-- 原子轉移 owner 身份（LS058／LS059／LS060）。PLAN §9-A2；來源見 LS-144 巡檢
-- 對 LS-192 票文的核對（「family_members 角色與移除／轉移 Owner／退出 RPC」
-- 實際不存在，且轉移 Owner 目前只是兩次直接 UPDATE，非原子）。
--
-- ---------------------------------------------------------------------------
-- 1. family_members BEFORE DELETE 守門（LS057）
-- ---------------------------------------------------------------------------
--
-- 既有的 private.enforce_family_has_owner()（LS-6，20260822120100_triggers.sql）
-- 是 AFTER DELETE/UPDATE 的 STATEMENT-level trigger：statement 結束後檢查「這個
-- 家庭還有沒有 owner」，沒有就整句 raise LS001 回滾。這支既有 trigger 涵蓋的範圍
-- 比本票要新增的守門更廣（不論家庭是否還有其他成員，只要 0 owner 就擋），本票
-- 新增的 BEFORE DELETE ROW-level trigger 是**更窄、訊息更明確**的第一道防線：
-- 專門攔「role='owner' 且該家庭無其他 owner、但仍有其他成員」這個最常見、最值得
-- 給出可行動建議（「先轉移 owner」＋ DETAIL 帶 family_id/family_name）的情境，
-- 在 LS001 那句籠統訊息噴出來之前，用 LS057 給更精準的訊息。BEFORE ROW（不是
-- STATEMENT）是必要的：BEFORE trigger 不能帶 transition table
-- （`referencing old table`只允許 AFTER trigger），且本身邏輯只需要看「這一列」
-- 被刪除後的結果，不需要看整個 statement 的批次效果。
--
-- 判斷邏輯（第 2 點以外都排除「正在被刪除的這一列自己」，因為 BEFORE trigger
-- 觸發時這一列在 family_members 裡實際上還沒被刪掉）：
--   1. OLD.role <> 'owner' → 跟 owner 不變量無關，一律放行。
--   2. families 裡已經找不到這個 family_id → 家庭本身正被同一句 DELETE 的
--      cascade 一併清除，一律放行（見下方推演）。
--   3. 排除自己後，這個家庭還有其他 owner → 放行（不會導致 0 owner）。
--   4. 排除自己後，這個家庭已經沒有任何其他成員（唯一成員退出）→ 放行，見下方
--      「刻意不做的事」。
--   5. 以上皆非（role=owner、無其他 owner、但仍有其他成員）→ raise LS057。
--
-- 與既有兩條「先升格、再移除」路徑天然相容，不需要 pg_trigger_depth()／GUC 後門
-- （票文原本准許用其中一種，這裡兩條都能用「查詢時看到的是本交易目前為止的最新
-- 已提交狀態」這個 read-committed 內建行為自然放行，寫清楚推演如下）：
--   - finalize_account_deletion()（service_role 路徑，20260904080802_
--     finalize_account_deletion_media.sql）：唯一 owner 的分支先用一句獨立的
--     UPDATE 把「家庭裡最早加入的其他成員」升為 owner、**再**對 p_user 執行
--     DELETE。本 trigger 對 p_user 這一列觸發時，那句 UPDATE 已經是同一交易內
--     先執行、已生效的既有事實，「排除自己後是否還有其他 owner」的查詢會看到
--     那位新 owner，直接落入條件 3 放行——不需要特殊處理（merge-review R1 i1：
--     這裡原本誤寫成「條件 2」，條件 2 是上面 families 存在性檢查，不是這一條）。
--   - delete_my_account() 情況 2（唯一成員，20260904070941_
--     delete_account_media.sql）與情況 3 一般離開路徑裡「整個家庭被砍」的
--     cascade（`delete from public.families`）：families 的父列在 FK cascade
--     觸發子表刪除之前就已經從表裡移除，本函式因此**一開始就先查 families
--     是否還在**（見下方函式體），查不到就直接放行，不理會 family_members
--     此刻殘留幾筆／處理順序為何。這一步不只是為了「唯一成員」這個特例：
--     FK cascade 對同一句 DELETE 影響的多筆子列，處理順序沒有保證——一個
--     3 人家庭整個被刪除時，若 cascade 剛好先處理到 owner 那一列，此時其他
--     兩列可能都還沒被刪，若不先判斷「families 還在不在」，會被本函式誤判
--     成「還有其他成員」而擋下（這是實作過程中用 00_fixtures.sql 的 A 家
--     `delete from families` 實測抓到的真實案例，不是理論推演——最初版本
--     只檢查 family_members、沒有比照既有 enforce_family_has_owner() 先確認
--     families 是否還在，三人家庭整個刪除時視 cascade 處理順序偶發 LS057）。
--
-- **刻意不做的事（deviation，寫清楚原因，供 merge-reviewer／orchestrator 核對）**：
-- 票文範圍 3 的驗收清單原字面要求「唯一 owner 且唯一成員退出 → 允許（家庭隨後
-- 可由 delete_my_account 處理）」，指的是**不經過 delete_my_account()、直接對
-- family_members 下一句 DELETE**（唯一成員自己離開，不刪 families 本身）也要
-- 放行。本 migration 刻意不實作這一句字面：這個場景與
-- `supabase/tests/concurrency/delete_account_race_*.sql`（LS-143，三輪
-- merge-review 才收斂）測的是**同一個資料庫狀態轉換**——「這句 DELETE 執行完，
-- family_members 對這個家庭恰好剩 0 列，但 families 那一列還在」——那組測試的
-- 前提正是：兩位共同 owner 幾乎同時呼叫 delete_my_account()，後動者一開始的
-- 快照判斷仍看到「還有另一位 owner」而走一般離開路徑，實際執行到一半、先動者已
-- 提交，後動者的 DELETE 因此意外把家庭清到 0 位成員——**這個結果必須被既有
-- LS001（AFTER STATEMENT trigger）擋下、強迫呼叫者重試**，重試時才會被正確判斷
-- 成「現在是唯一成員」而改走 `delete from families` cascade，家庭本身才會一併
-- 清掉。若把這個資料庫狀態轉換整個放行（不論是新增本 trigger 的例外、或修改
-- 既有 LS001 的判斷式），會讓上述併發測試的後動者不再拿到 LS001、悄悄成功，
-- 留下一個 families 列還在、但 family_members 掛零、永遠無法再被
-- delete_my_account() 的迴圈枚舉到（迴圈來源是「呼叫者目前所屬的家庭」，這時
-- 已經不屬於任何人）——這不是「家庭隨後可由 delete_my_account 處理」，而是
-- 一個沒有 owner、沒有任何成員、也永遠不會再被任何既有路徑清理的孤兒列，比
-- 現況（強迫多一次重試）更糟。這兩個場景在 trigger 層級無法用呼叫者身份區分
-- （都只是「對 family_members 的一句 DELETE」），本 migration 的判斷是：保留
-- 三輪加固過的既有併發安全網優先於票文這一句字面，**不修改
-- private.enforce_family_has_owner()**——唯一 owner 兼唯一成員若想離開自己的
-- 獨居家，唯一路徑維持是 delete_my_account()（本來就會正確 cascade 掉整個
-- 家庭，不會留下孤兒列），這件事本來就一直可行，不受本票影響。下方測試檔
-- 108_family_ownership_guard.sql 這個情境的斷言因此是「仍被 LS001 擋下」而不是
-- 票文字面的「允許」，並在該處重複這段推演供之後的人對照。
create or replace function private.enforce_ownership_transfer_before_leave()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family_name text;
begin
  if old.role <> 'owner' then
    return old;
  end if;

  -- 家庭本身正被同一句 DELETE 的 FK cascade 一併刪除（例如
  -- delete_my_account() 情況 2 的 `delete from families`）——families 的父列
  -- 在 cascade 觸發子表刪除之前就已經從表裡移除，這裡查不到即代表如此，
  -- 直接放行，不需要理會 family_members 目前殘留的列有幾筆／處理順序為何
  -- （FK cascade 對同一句 DELETE 影響的多筆子列，處理順序沒有保證——若不先
  -- 判斷這一條，一個 3 人家庭整個被刪除時，若 cascade 先處理到 owner 那一列，
  -- 這時其他兩列可能都還沒被刪，會被本函式誤判成「還有其他成員」而擋下，
  -- 沿用既有 private.enforce_family_has_owner() 同一種「先確認家庭是否還在」
  -- 的防呆寫法）。
  if not exists (select 1 from public.families f where f.id = old.family_id) then
    return old;
  end if;

  if exists (
    select 1 from public.family_members m
     where m.family_id = old.family_id
       and m.role = 'owner'
       and m.user_id <> old.user_id
  ) then
    return old;
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = old.family_id
       and m.user_id <> old.user_id
  ) then
    return old;
  end if;

  select f.name into v_family_name from public.families f where f.id = old.family_id;

  raise exception '你是「%」的唯一 owner，且家庭還有其他成員，須先把 owner 身份轉移給其他成員才能退出或被移除', v_family_name
    using errcode = 'LS057',
          detail = json_build_object('family_id', old.family_id, 'family_name', v_family_name)::text;
end;
$$;

create trigger family_members_ownership_transfer_guard
  before delete on public.family_members
  for each row execute function private.enforce_ownership_transfer_before_leave();

comment on function private.enforce_ownership_transfer_before_leave() is
  'LS-206：唯一 owner 且家庭仍有其他成員時，擋下對 family_members 的 DELETE
  （自行退出或被移除皆同），回 LS057（DETAIL 帶 {"family_id","family_name"}）。
  範圍刻意窄於既有 private.enforce_family_has_owner()（LS001）：唯一 owner 兼
  唯一成員的情況本 trigger 放行（見本檔檔頭「刻意不做的事」），交由既有 LS001
  與 delete_my_account() 處理，不在這裡放寬。';

-- ---------------------------------------------------------------------------
-- 2. transfer_ownership(p_family_id, p_to_user_id)：原子轉移 owner 身份
-- ---------------------------------------------------------------------------
--
-- 取代 LS-192 票文原本設想的「owner 對 family_members.role 兩次直接 UPDATE」
-- （升對方、降自己）——那條路徑非原子，且無法在「轉移」與「同時退出／另一筆
-- 轉移」之間排隊。既有的直接 UPDATE 路徑本身**保留**（family_members_update
-- policy，20260822120200_rls_policies.sql／LS-6／LS-33 收斂不動）：API.md 會
-- 標明「轉移請走本 RPC，直接改 role 只保留給單向升格（例如 owner 加開一位
-- 共同 owner，不涉及自己降級）」。
--
-- 鎖序：**兩句各自的 `perform ... for update`，固定用 least/greatest(caller,
-- target) 排出全域一致的 user_id 遞增序**——不是單一句「... where user_id in
-- (a, b) order by user_id for update」：ORDER BY 只保證這句查詢*輸出*的順序，
-- 不保證底層掃描／取鎖的實際順序，兩個併發呼叫若參數順序相反，仍可能以不同
-- 順序取鎖而死鎖。兩句各自的 statement 沒有這個歧義，**任兩筆 transfer_
-- ownership 呼叫彼此之間**（不論呼叫者／對象怎麼交錯）都會依 user_id 遞增序
-- 排隊，不會互為死鎖（`supabase/tests/concurrency/transfer_race_*.sql` 兩
-- session 實測驗證）。
--
-- **範圍收斂聲明（merge-review R1 m2，PLAUSIBLE、未實測重現）**：上面「不會
-- 互為死鎖」只涵蓋 transfer_ownership 彼此之間，**不涵蓋** family_members 上
-- 另外兩條也取列鎖的既有路徑——delete_my_account()
-- （`20260904212530_suspension_and_registrations.sql`）與
-- finalize_account_deletion()（`20260904080802_
-- finalize_account_deletion_media.sql`）：兩者都是單一句
-- `perform 1 from public.family_members where family_id = X for update`，
-- 一次鎖住這個家庭的**全部**成員列、沒有 `order by`，實際取鎖順序由查詢計畫
-- 決定（小表常見 seq scan → heap 實體順序，不保證等於 user_id 遞增序）。若
-- owner A 對某家庭呼叫 transfer_ownership（依 user_id 遞增鎖兩列）、同一家庭
-- 的成員 B 同時呼叫 delete_my_account()（一句鎖全部列、順序不保證），兩者
-- 取鎖順序若剛好相反並交錯，會被 Postgres 偵測到 `40P01` deadlock、砍掉其中
-- 一筆交易——**這不是本 PR 新引入的鎖、也不會資料損壞**（既有兩條路徑本來就
-- 是這樣鎖），`40P01` 是 Postgres 自己偵測後主動中止其中一方，另一方能正常
-- 完成；被中止那一方對呼叫端而言是一般性交易失敗，比照既有慣例重試同一個
-- 呼叫即可（不需要客製化的錯誤處理，PostgREST／supabase-swift 對交易失敗本來
-- 就是整個呼叫回傳失敗、由呼叫端決定要不要重試）。這個跨路徑風險本票**不**
-- 動 delete_my_account()／finalize_account_deletion() 既有的鎖法去消除它
-- （既有函式的鎖序是三輪 merge-review 才收斂的既有安全網，不在本票範圍內
-- 重新調整），僅在此如實記錄範圍邊界，避免之後的人誤以為「不會互為死鎖」
-- 涵蓋所有跟 family_members 有關的路徑。
--
-- 為什麼要在讀 role 之前先鎖：避免 TOCTOU——若先不鎖直接 SELECT role 做判斷、
-- 通過後才執行 UPDATE，SELECT 到 UPDATE 之間，對方可能剛好被移除／自行退出，
-- 或呼叫者剛好被另一筆併發的 transfer_ownership／owner 移除動作降級，這句
-- UPDATE 仍會照樣送出去（UPDATE 對「已被併發交易刪除但尚未提交」的列會等待
-- 對方 commit，之後用新版本重新求值 WHERE，可能悄悄變成影響 0 列而不噴錯，
-- 呼叫端拿到「成功」但實際上什麼也沒發生）。先鎖兩列，才能保證下面讀到的
-- role 是「鎖定當下最新已提交」的值，通過檢查之後的 UPDATE 一定如實反映。
--
-- 併發案（供 108_family_ownership_guard.sql 對照）：同一位 owner 幾乎同時對
-- 兩個不同對象各發一次 transfer_ownership——鎖序讓兩筆呼叫依 user_id 遞增序
-- 排隊，先取得鎖的那筆完整跑完並 commit（呼叫者降為 member、對象升為
-- owner）；後排的那筆鎖解開後，用全新查詢重新讀呼叫者的 role，此時已經是
-- 'member'，正確噴出 LS058，不會讓兩個人都被錯誤地扶正成 owner。
create or replace function public.transfer_ownership(p_family_id uuid, p_to_user_id uuid)
returns table(from_user_id uuid, from_role public.family_role, to_user_id uuid, to_role public.family_role)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_from_role public.family_role;
  v_to_role public.family_role;
begin
  if v_caller is null then
    raise exception '未登入，無法轉移 owner 身份' using errcode = '42501';
  end if;

  if p_to_user_id = v_caller then
    raise exception '不能把 owner 身份轉移給自己' using errcode = 'LS060';
  end if;

  perform 1 from public.family_members
   where family_id = p_family_id and user_id = least(v_caller, p_to_user_id)
   for update;
  perform 1 from public.family_members
   where family_id = p_family_id and user_id = greatest(v_caller, p_to_user_id)
   for update;

  select m.role into v_from_role from public.family_members m
   where m.family_id = p_family_id and m.user_id = v_caller;

  if v_from_role is distinct from 'owner' then
    raise exception '你不是這個家庭目前的 owner，無法轉移 owner 身份' using errcode = 'LS058';
  end if;

  select m.role into v_to_role from public.family_members m
   where m.family_id = p_family_id and m.user_id = p_to_user_id;

  if v_to_role is null then
    raise exception '對方不是這個家庭目前的成員，無法把 owner 身份轉移給他' using errcode = 'LS059';
  end if;

  update public.family_members set role = 'owner'
   where family_id = p_family_id and user_id = p_to_user_id;

  update public.family_members set role = 'member'
   where family_id = p_family_id and user_id = v_caller;

  return query select v_caller, 'member'::public.family_role, p_to_user_id, 'owner'::public.family_role;
end;
$$;

revoke execute on function public.transfer_ownership(uuid, uuid) from public, anon;
grant execute on function public.transfer_ownership(uuid, uuid) to authenticated;

comment on function public.transfer_ownership(uuid, uuid) is
  'LS-206：原子轉移 owner 身份（同一交易升對方、降自己）。呼叫者須為該家庭目前
  的 owner（否則 LS058）；p_to_user_id 須為該家庭目前的成員（否則 LS059）；
  p_to_user_id 不能等於呼叫者自己（LS060）。FOR UPDATE 鎖序見本 migration 檔頭
  第 2 節。既有的直接 UPDATE family_members.role 路徑不受影響，仍保留給單向
  升格；轉移請一律走本 RPC。';
