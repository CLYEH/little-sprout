-- LS-58（LS-22 後端切片）— comments／reactions 寫入 RPC、留言分頁讀取、reaction 彙總、
-- notification_events 資料面＋RLS。無 UI、無 Edge Function 發送（發送另票）。
--
-- ---------------------------------------------------------------------------
-- 0. 設計裁量 1：comments 的寫入面收斂成 RPC-only（比照 diaries，不是延續 LS-52 的
--    hybrid 模式）
--
-- LS-52（20260825010000_albums_comments_owner_scope.sql）已經把 albums／comments 的
-- owner 分支洞補上，但刻意保留作者本人的直接 `.insert()`／`.update()` 路徑（hybrid
-- 模式，理由見該檔案：「這個洞只出在 owner 分支，建立者改自己內容的那個分支本來就
-- 沒有問題」）。本票新增 create_comment／update_comment 兩支 RPC 之後，comments 的
-- 寫入面改成跟 diaries 一樣的 RPC-only（收回 authenticated 對 comments 的 INSERT／
-- UPDATE grant，comments_insert／comments_update 兩條 policy 一併 ALTER 成拒絕）。
--
-- 為什麼現在改，而不是繼續沿用 LS-52 的 hybrid：
--   1. 本票需要在「留言／愛心新增」的當下產生 notification_events（第 3 段）——
--      AFTER INSERT trigger 掛在資料表上，不論寫入路徑是 RPC 還是直接 `.insert()`
--      都會觸發，這件事本身不要求 RPC-only。但 list_comments（第 2 段）與
--      create_comment 都需要一個地方掛「作者是不是現在還是這個家庭的成員」這類
--      跨欄位授權判斷，讓寫入路徑統一收斂到 RPC，往後不必再維護兩條並存的授權
--      表達方式（policy 版 vs RPC 版），對齊 diaries 已經走過的路。
--   2. 更關鍵的理由：direct `.insert()` 目前完全沒有欄位級收斂——任何家庭成員可以
--      對 `target_type`／`target_id` 填任意值（多型關聯本來就沒有 FK 擋，見 §5「已知
--      代價」），RPC 版本至少讓「留言」這個動作有一個單一、可稽核的入口，之後若要
--      加防濫用限制（例如同一分鐘留言篇數上限）不必回頭改 policy。
--
-- 收斂方式沿用 diaries／LS-37 的既有慣例：ALTER POLICY ... (WITH CHECK) (false)，
-- 不是 DROP POLICY——縮權不是刪除物件、可逆、不動任何既有資料（理由詳見
-- 20260824010000_diaries_write_path_and_timeline.sql 第 1 段，這裡不重複整段展開）。
--
-- 對呼叫端而言這是一個真實的行為變更（comments 直接 INSERT/UPDATE 自本 migration
-- 起一律 42501，不是純新增；COLLABORATION §6：LS-25 之前全部 RPC 視為上線前，PR body
-- 的 BREAKING 段落此時非必需，這裡改用 migration 註解本身記錄），docs/API.md §2/§3
-- 同步更新。
-- ---------------------------------------------------------------------------

alter policy comments_insert on public.comments with check (false);
alter policy comments_update on public.comments using (false) with check (false);

revoke insert, update on public.comments from authenticated;

comment on table public.comments is
  '家庭留言。INSERT／UPDATE（內容）／軟刪唯一的寫入路徑分別是 public.create_comment() / '
  'public.update_comment() / public.set_comment_deleted()（LS-58 收斂，取代 LS-52 的 hybrid '
  '模式）—— authenticated 沒有 INSERT／UPDATE 的 policy 也沒有 grant。硬刪（DELETE）仍走 '
  '20260822120200_rls_policies.sql 既有的 comments_delete policy（僅 owner），未受本檔影響。'
  '註：20260825010000_albums_comments_owner_scope.sql 裡 comments_update 的定義（作者本人可'
  '直接 UPDATE）已被本檔的 ALTER POLICY 取代，以本說明為準。';

-- ---------------------------------------------------------------------------
-- 0b. 設計裁量 2：reactions 的寫入面也收斂成 RPC-only（toggle_reaction 取代直接
--     INSERT／DELETE）
--
-- 收斂前（20260822120200_rls_policies.sql）：reactions_insert／reactions_delete
-- 兩條 policy 允許任何家庭成員直接 `.insert()`／`.delete()`，docs/API.md §3 明寫
-- 呼叫端要自己處理重複按讚的 `23505`（「client 應該先查有沒有按過，或把 23505 當成
-- 「已經按過」處理」）——這是把冪等性的負擔推給每個呼叫端，且兩個併發呼叫互相
-- 競爭時沒有任何序列化保證。
--
-- toggle_reaction（第 1 段）用 pg_advisory_xact_lock 把「查有沒有按過→加或收回」
-- 序列化成單一原子操作，呼叫端不再需要自己處理 23505。既然有了這支 RPC，繼續留著
-- 直接 INSERT／DELETE 兩條路徑只是保留一個「舊的、不冪等」的旁路，沒有理由並存
-- （不像 albums／comments 的 hybrid 是因為作者對自己內容有持續的創作權要保留；
-- reactions 沒有「編輯」的概念，加或收回本來就是同一個操作的兩面，天生適合單一
-- RPC 表達）。收斂為 RPC-only，直接 INSERT／DELETE 一律 42501。
-- ---------------------------------------------------------------------------

alter policy reactions_insert on public.reactions with check (false);
alter policy reactions_delete on public.reactions using (false);

revoke insert, delete on public.reactions from authenticated;

comment on table public.reactions is
  '家庭愛心。加入／收回唯一的寫入路徑是 public.toggle_reaction()（LS-58 收斂）—— '
  'authenticated 沒有 INSERT／DELETE 的 policy 也沒有 grant。';

-- ---------------------------------------------------------------------------
-- 1. 寫入 RPC：create_comment／update_comment／toggle_reaction
--
-- 錯誤碼延續 LS023（set_album_deleted，LS-52）之後的序號：
--   LS025  不是留言作者本人，或雖是作者但已離開家庭（update_comment 專用，理由見下）
--   LS026  target 存在，但屬於別的家庭（create_comment／toggle_reaction 專用，理由見下）
-- LS024（留言不存在）沿用既有意義不變——update_comment 與 set_comment_deleted 共用
-- 同一個碼，且都只代表「不存在」，不像 diaries 的 LS020 那樣還兼指「已被軟刪除」
-- （update_comment 刻意不檢查 deleted_at，理由見該支函式內的說明：這不是 diaries
-- 那種通用規則，是 diaries 自己的產品決定）。
-- 42501（未登入／非本家庭成員／授權失敗的其他分支）沿用既有慣例。
-- ---------------------------------------------------------------------------

-- private.target_family_id：查多型 target 實際屬於哪個家庭（查不到就回 NULL）。
--
-- 為什麼需要這支函式（merge-reviewer PR #85 BLOCKER-1）：docs/API.md §3 原本寫
-- 「target_type／target_id 不驗證目標是否存在」，這句話對「孤兒 target_id」（誰都
-- 沒建過的 id）而言依然成立、不受本次修改影響；但沒說出口的另一半是「若 target_id
-- **真的存在**，呼叫端可以填任何 p_family_id，完全不必是那個 target 實際所屬的
-- 家庭」——這在加了 notification_events（本檔第 3 段）之後從「無害的資料髒污」
-- 變成真實的跨家庭挾持：被踢出的前成員只要還記得受害家庭裡任一 target_id（album／
-- media／diary／comment 的 id 從來就不是機密），就能用自己的 family_id 對那個
-- target 呼叫 create_comment／toggle_reaction，讓 notification_events 的合併視窗
-- 被算進攻擊者的家庭，蓋掉受害家庭真正成員的通知（本機實測重現：受害家庭的留言被
-- 合併進攻擊者那筆事件，`family_id` 變成攻擊者的）。
--
-- 修法：create_comment／toggle_reaction 在寫入前都先查 target 實際的 family_id，
-- **存在**且跟 `p_family_id` 不一致就直接 raise（LS026）——查不到（孤兒 target_id）
-- 則放行，維持既有裁量不擴大（前述「不驗證是否存在」那一半原封不動）。這支函式回傳
-- `NULL` 而不是自己 raise，讓兩支呼叫端各自決定「查不到」該怎麼辦，保持單一職責。
create or replace function private.target_family_id(
  p_target_type public.content_target_type,
  p_target_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_family_id uuid;
begin
  case p_target_type
    when 'album' then
      select a.family_id into v_family_id from public.albums a where a.id = p_target_id;
    when 'media' then
      select m.family_id into v_family_id from public.media m where m.id = p_target_id;
    when 'diary' then
      select d.family_id into v_family_id from public.diaries d where d.id = p_target_id;
    when 'comment' then
      select c.family_id into v_family_id from public.comments c where c.id = p_target_id;
  end case;
  return v_family_id;
end;
$$;

-- create_comment：任何角色（含 viewer）都能留言，比照收斂前 comments_insert policy
-- 的授權範圍——PLAN §3「Viewer 只能看與留言」是產品定案，不是本票的裁量。author_id
-- 一律是呼叫者本人，不接受由參數指定（防冒名，同 create_diary_entry／media_insert
-- 的 uploaded_by 慣例）。
create or replace function public.create_comment(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_body text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
  v_target_family uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法留言' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能留言' using errcode = '42501';
  end if;

  -- 見上方 private.target_family_id 的說明：查得到且不一致才擋，查不到（孤兒
  -- target_id）維持既有裁量放行。
  v_target_family := private.target_family_id(v_target_type, p_target_id);
  if v_target_family is not null and v_target_family <> p_family_id then
    raise exception '這個留言目標不屬於這個家庭' using errcode = 'LS026';
  end if;

  insert into public.comments (family_id, target_type, target_id, author_id, body)
  values (p_family_id, v_target_type, p_target_id, v_uid, p_body)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_comment(uuid, text, uuid, text) from public, anon;
grant execute on function public.create_comment(uuid, text, uuid, text) to authenticated;

-- update_comment：只有原作者能改內容（body），且必須「當下仍是該家庭任一角色的
-- 成員」——這是本票唯一一處刻意偏離 LS-48/52 一般模式（作者改內容通常要求仍是
-- contributor／owner-member）的地方，理由見 docs/API.md §3「comments」段既有的
-- 裁量說明（LS-52 已經定案）：comments_update policy 的作者分支從一開始就沒有排除
-- viewer（PLAN §3：Viewer 也能留言），這不是新放寬，是延續既有、已被記錄在案的
-- 產品決定；若這裡改成要求 contributor，會是一次未被記錄的縮權，且與
-- docs/API.md 現有文字直接矛盾。已被軟刪除的留言**仍可編輯**——這裡刻意不比照
-- update_diary_entry 加上「已軟刪除須先還原」的限制，理由見函式本體內的說明。
create or replace function public.update_comment(
  p_comment_id uuid,
  p_body text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_comment public.comments%rowtype;
begin
  if v_uid is null then
    raise exception '未登入，無法編輯留言' using errcode = '42501';
  end if;

  select c.* into v_comment from public.comments c where c.id = p_comment_id for update;

  if not found then
    raise exception '留言不存在' using errcode = 'LS024';
  end if;

  if v_comment.author_id is distinct from v_uid
     or not exists (
       select 1 from public.family_members m
        where m.family_id = v_comment.family_id and m.user_id = v_uid
     ) then
    raise exception '只有仍是該家庭成員的原作者能編輯這則留言' using errcode = 'LS025';
  end if;

  -- 刻意**不**檢查 deleted_at（跟 update_diary_entry 不同）：收斂前的 comments_update
  -- policy（LS-52）從來沒有「已軟刪除不能編輯」這條規則，albums_update 的作者分支
  -- 現在也還是沒有（見 supabase/tests/concurrency/album_edit_vs_delete_s2_update.sql
  -- 的既有回歸：owner 軟刪先動、作者的直接 UPDATE 後動仍然成功）。這支 RPC 只是把
  -- 既有的「作者可編輯自己內容」這條規則換個入口（RPC 取代直接 UPDATE），不是重新
  -- 設計授權語意，所以刻意不夾帶 diaries 那條限制——那是 diaries 自己的產品決定，
  -- 不是這個 schema 的通用規則（見 20260824010000_diaries_write_path_and_timeline.sql
  -- 對 update_diary_entry 的說明，那條限制沒有被其他表繼承的理由）。
  update public.comments c
     set body = p_body
   where c.id = p_comment_id;
end;
$$;

revoke execute on function public.update_comment(uuid, text) from public, anon;
grant execute on function public.update_comment(uuid, text) to authenticated;

-- toggle_reaction：加入／收回同一個操作的兩面。用 pg_advisory_xact_lock 把「查詢現況
-- →決定加或刪」序列化成單一原子操作，鎖鍵是 (target_type, target_id, user_id) 的雜湊
-- ——只序列化「同一人對同一目標」的並發呼叫，不同人或不同目標互不影響。沒有這把鎖，
-- 兩個併發呼叫（同一人對同一目標）會都查到「還沒按過」，都嘗試 INSERT，第二個會撞
-- reactions_target_user_key 的 23505；有了鎖，後到的呼叫會在鎖上排隊，解除後看到
-- 「已經按過」，改成收回——兩次呼叫都成功，淨效果正確歸零，不會有任何一次噴錯。
-- 見 supabase/tests/concurrency/reaction_toggle_race_*.sql 的雙 toggle 併發回歸。
--
-- 授權比照收斂前 reactions_insert policy：任何角色（含 viewer）都能按讚。
create or replace function public.toggle_reaction(
  p_family_id uuid,
  p_target_type text,
  p_target_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_target_type public.content_target_type := p_target_type::public.content_target_type;
  v_target_family uuid;
begin
  if v_uid is null then
    raise exception '未登入，無法按讚' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.family_members m
     where m.family_id = p_family_id and m.user_id = v_uid
  ) then
    raise exception '只有該家庭的成員能按讚' using errcode = '42501';
  end if;

  -- 同 create_comment：查得到且不一致才擋（LS026），查不到（孤兒 target_id）維持
  -- 既有裁量放行。見 private.target_family_id 與上方 create_comment 的完整說明
  -- （merge-reviewer PR #85 BLOCKER-1，reactions 與 comments 是同一種挾持面）。
  v_target_family := private.target_family_id(v_target_type, p_target_id);
  if v_target_family is not null and v_target_family <> p_family_id then
    raise exception '這個按讚目標不屬於這個家庭' using errcode = 'LS026';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(v_target_type::text || ':' || p_target_id::text || ':' || v_uid::text, 0)
  );

  -- 收回這一步的 DELETE 條件（target_type/target_id/user_id）不帶 p_family_id
  -- ——這是既有唯一鍵 reactions_target_user_key 的欄位組合。但這**不是**收回路徑
  -- 不受 p_family_id 約束：上面的 LS026 檢查排在這裡（與 lock）之前，加入與收回
  -- 兩條路徑都會先經過它。merge-reviewer PR #85 R2 F2 實測澄清了 R1 I3 原本高估
  -- 的殘餘範圍：對**真的存在**的 target，呼叫端想用跟先前不同的 p_family_id 收回
  -- 別人家庭底下的反應，會直接卡在 LS026（回錯誤、DELETE 完全不會執行，那個家庭
  -- 的反應原封不動）；殘餘情況只剩 target_id **完全查不到**（孤兒）的時候——
  -- private.target_family_id 回 NULL，LS026 檢查通不通過都放行，DELETE 這時才會
  -- 單靠 user_id 找到並收回「呼叫者對這個孤兒 id 的反應」，不論那顆反應當初是用
  -- 哪個 family_id 加的。這與孤兒 target_id 在 create_comment／toggle_reaction 加入
  -- 路徑本來就有的既有裁量（放行、不驗證存在）是同一件事的自然延伸，不是新洞。
  delete from public.reactions r
   where r.target_type = v_target_type
     and r.target_id = p_target_id
     and r.user_id = v_uid;

  if found then
    return false;
  end if;

  insert into public.reactions (family_id, target_type, target_id, user_id)
  values (p_family_id, v_target_type, p_target_id, v_uid);

  return true;
end;
$$;

revoke execute on function public.toggle_reaction(uuid, text, uuid) from public, anon;
grant execute on function public.toggle_reaction(uuid, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. 讀取 RPC：list_comments（keyset 分頁）／get_reaction_counts（彙總，避免 N+1）
-- ---------------------------------------------------------------------------

-- list_comments：單一 target 的留言分頁，含軟刪過濾（deleted_at is null）與作者
-- 顯示名（join profiles，避免呼叫端逐則留言各查一次作者資料的 N+1）。
--
-- security definer（不是 invoker——本機實測推翻了原本「比照 get_family_timeline
-- 選 invoker」的預設判斷，過程與證據如下）：
--   第一版寫成 security invoker，仰賴既有的 comments_select／profiles_select RLS
--   policy 做隔離，結構上跟 get_family_timeline 一樣。本機用 5 萬則留言（單一
--   target）灌測（見 supabase/tests/50_rls_plan_no_percall_subquery.sql）時發現：
--   即使 comments_target_idx（family_id, target_type, target_id, created_at）
--   完整存在、就算把其他競爭索引全部砍掉強迫規劃器選它，authenticated 身分下的
--   查詢一律選到 Bitmap Heap Scan／Seq Scan + 顯式 Sort（829-873 buffers），
--   而不是能提供現成排序、允許 LIMIT 提早結束的 Index Scan Backward；同一句 SQL
--   換成 postgres（不受 RLS）身分執行，規劃器正確選中 Index Scan Backward，只掃
--   21 列（7-8 buffers）。差異只在 RLS 的 `family_id in (select private.family_
--   ids())` 這個 hashed SubPlan 條件疊上去之後——規劃器對這個條件的選擇度估計
--   不準，連帶讓它認為「排序後的索引掃描要找到前 20 列」的成本高於「整段掃描＋
--   排序」，於是放棄了原本唯一能讓 LIMIT 提早結束的路徑。這與 get_family_timeline
--   的 F1 教訓同源（RLS 疊加造成規劃器誤判），但那次的解法（改寫成 plpgsql 拆分
--   靜態查詢）解決不了這次的問題——這裡的分支已經是靜態的，卡住的是 RLS 條件
--   本身對這張表這個查詢形狀的成本估計，不是 OR／inline。
--
--   改用 definer 之後，函式內部手動把「呼叫者是否為 p_family_id 的成員」的檢查
--   換成一句明確的 exists 查詢（比照 create_comment／toggle_reaction 的既有慣例），
--   跳過 RLS 的 hashed SubPlan，讓 comments/profiles 的查詢回到「乾淨」的等值條件，
--   規劃器正確選回 Index Scan Backward。副作用（刻意接受）：非本家庭成員呼叫這支
--   RPC 會拿到明確的 42501，不是 get_family_timeline 那種「不報錯、靜默回 0 列」——
--   這跟 diaries／comments 其餘 definer RPC 的既有慣例一致（呼叫端本來就該預期
--   definer RPC 對越權呼叫會噴錯，不是靜默空集合，這裡沒有必要為了跟
--   get_family_timeline 統一而犧牲已經量到的效能）。另一個副作用：author_display_
--   name／author_avatar_url 不再受 profiles_select 的 peer_profile_ids() 限制
--   （只顯示「目前」同家庭的人）——作者若已離開這個家庭，他過去留言的顯示名稱依然
--   看得到，不會變成 NULL。這其實是更合理的行為（留言串本來就該保留當時作者是誰的
--   紀錄），不是意外的資訊洩漏（display_name 在這個 app 的信任模型裡本來就只是暱稱，
--   不是需要跨家庭邊界保護的敏感資料）。
--
-- 內部結構刻意先在子查詢裡完成「篩選＋排序＋LIMIT」，才 LEFT JOIN profiles：
-- 讓 profiles 這個 join 永遠只吃已經被 LIMIT 夾住的 ≤100 列，不會被規劃器選成
-- Hash Join 而把 comments 那一側整批物化（本機實測：沒有這層子查詢邊界時，
-- LEFT JOIN 就算 comments 那側已經走對索引，仍可能被規劃器改選 Hash Join，
-- 讓 profiles 的 join 條件反過來拖著 comments 一起做 Seq Scan）。
--
-- 分頁邏輯比照 get_family_timeline 的 LS-48 F1 教訓：拆成「有游標／無游標」兩條
-- **靜態**查詢（不是同一句 SQL 裡的 OR 分支）。半游標（只傳 p_cursor_created_at／
-- p_cursor_id 其中一個）直接 raise，沿用 LS022（get_family_timeline 已經用過的
-- 碼——語意完全相同：keyset 分頁的游標參數只給了一半，不是 target 或 RPC 專屬的
-- 錯誤，沒有理由另開一個碼），不靜默回傳空集合。
-- 效能回歸見 supabase/tests/50_rls_plan_no_percall_subquery.sql 的專屬段落。
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

-- get_reaction_counts：批次彙總一頁內容（例如一頁留言、一頁相簿卡片）各自的愛心數，
-- 呼叫端傳一組 target_id 一次拿回全部計數，避免對每個 target 各查一次 COUNT 的 N+1。
-- 沒有任何反應的 target_id 不會出現在回傳列裡（GROUP BY 天生排除 0 筆的組合）——
-- 呼叫端要把缺席的 target_id 當成 0，同 get_my_join_request()「0 列＝空結果」的既有
-- 慣例，不是遺漏。language sql（單一靜態聚合查詢，沒有 OR／游標分支，不受 LS-48 F1
-- 的 inline 限制影響）。
--
-- 這支維持 security invoker（跟 list_comments 不同裁量，理由：這是純聚合查詢，
-- 沒有「排序＋LIMIT 提早結束」這個會被 RLS 選擇度誤判打斷的路徑——本機同樣用
-- 5000 筆反應（250 個 target）灌測過，invoker 身分下規劃器仍正確選用
-- reactions_target_idx，沒有出現 list_comments 那種 Bitmap／Seq Scan 退化，
-- 見 supabase/tests/50_rls_plan_no_percall_subquery.sql 的對應段落。維持 invoker
-- 保留 reactions_select 既有 RLS 做隔離，暴露面比 definer 小，這裡沒有理由為了
-- 「與 list_comments 一致」而放棄一個實測沒有問題的較小暴露面）。
create or replace function public.get_reaction_counts(
  p_family_id uuid,
  p_target_type text,
  p_target_ids uuid[]
)
returns table (
  target_id uuid,
  reaction_count bigint,
  reacted_by_me boolean
)
language sql
stable
set search_path = ''
as $$
  select r.target_id,
         count(*)::bigint as reaction_count,
         bool_or(r.user_id = (select auth.uid())) as reacted_by_me
    from public.reactions r
   where r.family_id = p_family_id
     and r.target_type = p_target_type::public.content_target_type
     and r.target_id = any (p_target_ids)
   group by r.target_id;
$$;

revoke execute on function
  public.get_reaction_counts(uuid, text, uuid[])
  from public, anon;
grant execute on function
  public.get_reaction_counts(uuid, text, uuid[])
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. notification_events：推播基礎——只做資料面（表＋trigger＋彙總視窗），發送由
--    Edge Function 另票（LS-22）處理，這裡不呼叫任何外部服務。
--
-- 彙總策略（PLAN §4「批次上傳 50 張照片要合併成一則」同一個精神）：同一個家庭
-- （family_id）、同一種事件（kind）、同一個目標（target_type + target_id）在 5
-- 分鐘內重複發生，合併成同一筆待送事件（event_count 累加、occurred_at 更新成最新
-- 一次、actor_id 換成最新觸發者）。這是**滾動視窗**（rolling window）：只要事件
-- 間隔小於 5 分鐘就持續延伸同一筆，不是從第一次事件起算的固定 5 分鐘桶——一段長
-- 時間的熱烈留言串會一直合併成同一筆，直到中斷超過 5 分鐘才開新的一筆。Edge
-- Function（LS-22）之後可以用 occurred_at 判斷「這筆事件已經穩定超過 5 分鐘沒有
-- 新動作」再送出，本票不實作那個判斷本身。
--
-- **合併鍵含 family_id（merge-reviewer PR #85 BLOCKER-1，不是原始設計，是修正）**：
-- target_type／target_id 是多型關聯、沒有 FK（見上方 create_comment／toggle_
-- reaction 對 private.target_family_id 的說明），schema 明文放棄保證「一個
-- target_id 只屬於一個家庭」這件事。若合併鍵只看 (kind, target_type, target_id)、
-- 不看 family_id，兩個不同家庭對「同一個 target_id」（例如被踢出的前成員手上的舊
-- album id）產生的事件會被合併成同一列，且那一列最終的 family_id 只會是其中一個
-- ——LS-22 的 Edge Function 依 family_id 決定通知對象，等於另一個家庭的通知被吞掉、
-- 錯的家庭收到一則指向自己讀不到的 target 的推播。create_comment／toggle_reaction
-- 已經在寫入前擋掉「target 存在但屬於別的家庭」（LS026），這是第一道、也是根治的
-- 防線；這裡的合併鍵加 family_id 是第二道防線（defense in depth）——即使第一道
-- 防線之後被弱化或繞過，同一個 target_id 底下不同家庭的事件也不會被合併成一列。
--
-- kind 與 target_type／target_id 分開：target_type／target_id 沿用 comments／
-- reactions 既有的多型關聯（'diary'／'album' 兩種 kind 則直接用該內容自己的 id），
-- 但同一個目標上「新留言」與「新愛心」是兩種不同的通知（推播文案不同：「X 留言了」
-- vs「X 按讚了」），必須各自累計、各自合併，不能因為 target 相同就混在一起——這是
-- kind 存在的理由，不能只靠 (target_type, target_id) 當合併鍵。
--
-- 併發：兩個幾乎同時發生的事件（例如兩人同時對同一篇日記留言）若沒有鎖，可能都查到
-- 「還沒有可合併的待送視窗」而各自 INSERT 一筆，變成兩筆本該合併的事件。用
-- pg_advisory_xact_lock（鎖鍵＝(family_id, kind, target_type, target_id) 的雜湊，
-- 同 toggle_reaction 的手法）序列化「查詢有無可合併視窗→更新或新增」，即使視窗還
-- 不存在也一樣序列化得到（advisory lock 不需要先有列才能鎖，這是選它而不是
-- `for update` 的原因——`for update` 得先有一列可鎖，序列化不了「兩者都在決定要不要
-- 新建第一筆」的那個時刻）。
--
-- **批次寫入改成先分組再合併（merge-reviewer PR #85 I1）**：四支 notify_* trigger
-- 函式原本逐列呼叫 record_notification_event（每列各自取一次鎖），對「一次 INSERT
-- 多列」的場景是 O(N) 次序列往返；本 schema 目前的實際寫入路徑（RPC 一次一列）從
-- 不會產生這種場景，但 supabase/tests/50_rls_plan_no_percall_subquery.sql 的效能
-- 探針故意灌了 5 萬列在同一個 target 上，逐列版本量到 26868ms、關掉 trigger 量到
-- 538ms（差 50 倍）。修法：trigger 函式先用 GROUP BY (family_id, target_type,
-- target_id) 把 new_rows 摺疊成「這一批裡有幾組不同的目標、每組幾筆、最新一位
-- actor 是誰」，record_notification_event 改吃一個 `p_increment` 筆數參數，對
-- 「同一批裡同一組目標」只呼叫一次（而不是呼叫 N 次、每次 +1）——鎖與視窗判斷邏輯
-- 完全不變，只是把「重複呼叫同一組參數 N 次」收斂成「呼叫一次、帶上 N」，語意上
-- 對單列寫入（RPC 的實際路徑）完全等價，只有多列寫入才會走到聚合的分支。沒有選
-- reviewer 建議的另一條路（拿掉 advisory lock、改用部分唯一索引＋
-- `INSERT … ON CONFLICT`）：5 分鐘滾動視窗是**時間相依**的合併規則，「是否可合併」
-- 取決於既有列的 occurred_at 有沒有超過 5 分鐘，這件事無法表達成一個靜態的
-- UNIQUE 約束（`sent_at IS NULL` 的部分唯一索引會把「視窗已經過期但 Edge Function
-- 還沒來得及標記 sent_at」的舊列也算進去，導致新事件永遠合併進一筆早就該關閉的
-- 舊視窗）——保留 advisory lock＋時間比對的既有判斷邏輯，只把「重複呼叫」收斂掉，
-- 是能同時修好效能又不改動合併規則語意的最小改動。
-- ---------------------------------------------------------------------------

create type public.notification_kind as enum ('comment', 'reaction', 'diary', 'album');

create table public.notification_events (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.notification_kind not null,
  target_type public.content_target_type not null,
  target_id uuid not null,
  actor_id uuid references public.profiles (id) on delete set null,
  event_count integer not null default 1 check (event_count > 0),
  first_occurred_at timestamptz not null default now(),
  occurred_at timestamptz not null default now(),
  -- NULL＝待送；Edge Function（service_role，LS-22）送出後寫入。本票不寫這一欄。
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.notification_events is
  '推播彙總佇列（資料面，LS-58）。由 comments／reactions／diaries／albums 的 AFTER '
  'INSERT statement-level trigger（private.notify_*）呼叫 private.record_notification_'
  'event() 維護：同一 kind＋target 在 5 分鐘滾動視窗內的多次事件合併成一筆（event_count '
  '累加）。發送邏輯（挑出 occurred_at 已穩定的待送列、決定通知對象、呼叫 APNs）由 '
  'LS-22 的 Edge Function 負責，只用 service_role 讀寫，此表對 authenticated 沒有任何 '
  'grant，成員無法直接讀取（見 docs/API.md 對本表的設計說明）。';

-- 反向索引（LS-34 慣例）：family_id／actor_id 兩個 FK 各自需要能服務等值查找的索引，
-- 這兩個索引同時也是查詢面用得到的形狀（family_id 供未來 debug／稽核用；actor_id
-- 供 auth.users 被刪除、profiles cascade 或 set null 時的參照完整性檢查）。
create index notification_events_family_idx
  on public.notification_events (family_id, occurred_at desc);
create index notification_events_actor_idx
  on public.notification_events (actor_id);

-- Edge Function（LS-22）掃描待送事件用：sent_at is null 的部分索引，依 occurred_at
-- 排序即可找出「視窗已經穩定超過 5 分鐘」的列。
create index notification_events_pending_idx
  on public.notification_events (occurred_at)
  where sent_at is null;

-- trigger 合併判斷用：同一 kind／target 底下最新一筆待送事件的查找鍵。
create index notification_events_merge_idx
  on public.notification_events (kind, target_type, target_id, occurred_at desc)
  where sent_at is null;

alter table public.notification_events enable row level security;
-- 刻意不建立任何 policy：成員完全不可讀（§ 上方說明）。這張表對 authenticated／anon
-- 也沒有任何 table grant（沿用 init_schema.sql 的 default-revoke，新表天生零權限，
-- 見 supabase/tests/65_fk_reverse_index.sql／60_default_privileges.sql 相關段落），
-- 兩層防線（grant 與 RLS）都不開放，PostgREST 會在到達 RLS 之前就先被 grant 層擋下
-- （42501），跟 feed_items 那種「有 grant、靠 RLS 篩」的唯讀表不同形狀。

-- **service_role 也要明確 grant（merge-reviewer PR #85 應修-1，修正原本的誤判）**：
-- 這張表原本以為「public schema 新表對 postgres/service_role 的預設權限」跟其他表
-- 一樣夠用，本機 `\dp` 實測推翻了這個假設——`pg_default_acl` 對 public schema 的
-- tables，postgres 的預設只給 service_role `Dxtm`（TRUNCATE/REFERENCES/TRIGGER/
-- MAINTAIN），**沒有 r/a/w/d**；其他表沒撞到這個洞是因為它們的實際存取者是
-- `authenticated`（逐表明文 grant），`notification_events` 是本 schema 第一張
-- 「只給 service_role」的表，才第一次真的踩到這個預設破口。`BYPASSRLS`
-- 只跳過 policy，跳不過 grant 層，兩者是獨立的兩道防線。
--
-- 不依賴會因環境而異的平台預設，這張表自己的 migration 把它釘住——本 repo 已有
-- 先例（`20260822120300_harden_default_privileges.sql` §2 對 sequences 就是同一
-- 個理由同一種修法）。只給送出流程實際需要的兩個動作：讀取待送事件、標記
-- `sent_at`；DELETE 留給日後的 retention 策略決定（見 migration 檔尾／API.md 對
-- 本表的說明），這裡不先開。
grant select, update on public.notification_events to service_role;

-- 合併寫入的共用邏輯：找同 family_id／kind／target 底下最新一筆「還沒送出且 5 分鐘
-- 內」的待送事件，找到就更新（event_count 累加 p_increment、occurred_at 推進、
-- actor 換成最新觸發者），找不到就新開一筆（event_count 直接等於 p_increment）。
-- p_increment（LS-58 R1，I1）：呼叫端（notify_* trigger 函式）可能是「這一批裡
-- 同一組目標出現了 N 次」聚合過的結果，不一定是單一事件——單一事件呼叫時
-- p_increment 恆為 1，跟原本逐次呼叫、每次 event_count+1 的語意完全等價。
create or replace function private.record_notification_event(
  p_family_id uuid,
  p_kind public.notification_kind,
  p_target_type public.content_target_type,
  p_target_id uuid,
  p_actor_id uuid,
  p_increment integer default 1
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing_id uuid;
begin
  -- 鎖鍵含 p_family_id（LS-58 R1，BLOCKER-1 第二道防線）：即使 p_target_id 剛好被
  -- 兩個不同家庭同時引用，兩邊的合併判斷也序列化在各自的鎖上，不會互相卡到——但
  -- 「合不合併」的判斷本身還是看下面 SELECT 的 family_id 條件，鎖只負責序列化，
  -- 不負責篩選。
  perform pg_advisory_xact_lock(
    hashtextextended(
      p_family_id::text || ':' || p_kind::text || ':' || p_target_type::text || ':' || p_target_id::text,
      0
    )
  );

  select e.id into v_existing_id
    from public.notification_events e
   where e.family_id = p_family_id
     and e.kind = p_kind
     and e.target_type = p_target_type
     and e.target_id = p_target_id
     and e.sent_at is null
     and e.occurred_at >= now() - interval '5 minutes'
   order by e.occurred_at desc
   limit 1
   for update;

  if v_existing_id is not null then
    update public.notification_events e
       set occurred_at = now(),
           event_count = e.event_count + p_increment,
           actor_id = p_actor_id
     where e.id = v_existing_id;
  else
    insert into public.notification_events (family_id, kind, target_type, target_id, actor_id, event_count)
    values (p_family_id, p_kind, p_target_type, p_target_id, p_actor_id, p_increment);
  end if;
end;
$$;

-- 四張來源表各自的 statement-level trigger 函式（比照本 schema 既有的 feed_sync_*
-- 慣例：AFTER INSERT、REFERENCING NEW TABLE AS new_rows、FOR EACH STATEMENT，批次
-- 寫入只觸發一次函式呼叫，逐列處理 new_rows，不是每列各自觸發一次 trigger）。
--
-- 只在 INSERT 產生通知：留言／按讚的收回、日記／相簿的編輯或軟刪都不通知（PLAN §2
-- 「有新照片/日記/留言時通知」——新增才是通知的觸發條件，這也是為什麼四支函式只掛
-- AFTER INSERT，不像 feed_sync_* 還要處理 UPDATE／DELETE）。
create or replace function private.notify_comment_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- LS-58 R1（I1）：先按 (family_id, target_type, target_id) 分組，一組只呼叫一次
  -- record_notification_event（帶上這組的筆數與最新一位作者），不是逐列各呼叫一次。
  -- actor 取這組裡 created_at 最新的一列，單列寫入（RPC 的實際路徑）時這組必然只有
  -- 一列，跟原本逐列版本完全等價。
  for r in
    select family_id, target_type, target_id,
           count(*)::integer as n,
           (array_agg(author_id order by created_at desc))[1] as actor_id
      from new_rows
     group by family_id, target_type, target_id
  loop
    perform private.record_notification_event(
      r.family_id, 'comment', r.target_type, r.target_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger comments_notify_insert after insert on public.comments
  referencing new table as new_rows
  for each statement execute function private.notify_comment_created();

create or replace function private.notify_reaction_added()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- 同 notify_comment_created 的分組手法。reactions 沒有 created_at 欄位可排序
  -- 「最新」，同一組裡任取一個 user_id 當 actor——單列寫入（toggle_reaction 的實際
  -- 路徑）這組必然只有一列，語意不受影響；多列只會發生在批次灌測資料的場景。
  for r in
    select family_id, target_type, target_id,
           count(*)::integer as n,
           (array_agg(user_id))[1] as actor_id
      from new_rows
     group by family_id, target_type, target_id
  loop
    perform private.record_notification_event(
      r.family_id, 'reaction', r.target_type, r.target_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger reactions_notify_insert after insert on public.reactions
  referencing new table as new_rows
  for each statement execute function private.notify_reaction_added();

-- diary／album 的通知目標就是內容自己（target_type／target_id＝該篇日記／相簿本身），
-- 跟 comments／reactions 引用的是「被留言／被按讚的目標」不同。
create or replace function private.notify_diary_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- diary／album 的 target_id 是每篇日記／每本相簿自己的 id，天生互不相同，同一批
  -- new_rows 裡不會有兩列落在同一組——這裡的 GROUP BY 對單列與多列寫入都是恆等
  -- 變換（每組必然剛好 1 列），純粹是跟另外兩支函式維持同一套寫法，不是為了效能
  -- （diaries／albums 目前也只會一次一列寫入）。
  for r in
    select family_id, id as target_id, count(*)::integer as n,
           (array_agg(author_id order by created_at desc))[1] as actor_id
      from new_rows
     group by family_id, id
  loop
    perform private.record_notification_event(r.family_id, 'diary', 'diary', r.target_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger diaries_notify_insert after insert on public.diaries
  referencing new table as new_rows
  for each statement execute function private.notify_diary_created();

create or replace function private.notify_album_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- 同 notify_diary_created 的說明：album 的 target_id 也是每本相簿自己的 id，
  -- GROUP BY 對這張表同樣是恆等變換，維持同一套寫法。
  for r in
    select family_id, id as target_id, count(*)::integer as n,
           (array_agg(created_by order by created_at desc))[1] as actor_id
      from new_rows
     group by family_id, id
  loop
    perform private.record_notification_event(r.family_id, 'album', 'album', r.target_id, r.actor_id, r.n);
  end loop;
  return null;
end;
$$;

create trigger albums_notify_insert after insert on public.albums
  referencing new table as new_rows
  for each statement execute function private.notify_album_created();

-- ---------------------------------------------------------------------------
-- 4. schema private 的 EXECUTE 收斂（比照 rls_policies.sql 檔尾同一句慣例）——
--    本票新增的六支 private 函式（target_family_id／record_notification_event／
--    notify_comment_created／notify_reaction_added／notify_diary_created／
--    notify_album_created）預設對 PUBLIC 開放 EXECUTE，這裡收回；authenticated
--    不需要也不應該直接呼叫這些內部判斷／trigger 函式。
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public;

-- ---------------------------------------------------------------------------
-- 5. 已知缺口登記（merge-reviewer PR #85 I8，不在本票範圍內修，留紀錄不留空白）：
--    notification_events 目前沒有任何 retention／清理路徑——已送出（sent_at is not
--    null）的列會一直留著，也沒有涵蓋 sent_at 非空列的索引（notification_events_
--    pending_idx 是 `where sent_at is null` 的部分索引，只服務待送查詢）。這張表會
--    單向成長。票文沒有要求這件事，留給 LS-22（Edge Function 送出流程定案時，順便
--    決定要保留多久、多久清一次）或後續票，不在這裡先猜一個保留期限。
-- ---------------------------------------------------------------------------
