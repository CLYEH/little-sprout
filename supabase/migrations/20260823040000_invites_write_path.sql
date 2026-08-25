-- LS-37 — invites 的寫入路徑收斂：唯一寫入路徑是 create_invite RPC
--
-- 來源：LS-33／LS-12／LS-34 批次收尾的 dead-code-sweeper 觀察項（既有債，非該批引入）。
--
-- 問題：20260822120200_rls_policies.sql 的 invites_insert 讓 owner 可以完全繞過
-- create_invite，直接對 invites 表寫一列——於是那支 RPC 建立的三道邊界全部形同虛設：
--   - 到期時間 ≤ 30 天（LS017）
--   - 可用次數 1–20（LS017）
--   - 邀請碼的正規化形式（8 碼、大寫、23456789ABCDEFGHJKLMNPQRSTUVWXYZ）
-- 一句 `insert into public.invites (..., max_uses, expires_at) values (..., 100000,
-- now() + interval '100 years')` 就能造出一支「永不過期、可用十萬次」的碼。而 max_uses
-- 與 expires_at 正是 PLAN §5／§8 用來限制「碼外流之後果」的那兩個旋鈕：它們可以被
-- 呼叫端自己填，等於這個家庭一旦碼外流就永久對外開放。
--
-- 這是 LS-33 對 family_members 做過的同一件事的第二半：那次關掉的是「owner 可以不經
-- 邀請碼直接把人塞進成員名單」，這次關掉的是「owner 可以不經 create_invite 直接造一支
-- 不受限制的邀請碼」。兩者的終點相同——陌生人進到家庭裡。
--
-- 三個決定，逐項寫在下面各段：
--   1. INSERT 兩層都關（policy + grant），唯一寫入路徑是 create_invite。
--   2. UPDATE 兩層都關。invites 沒有任何一個「撤銷用」欄位可以留給呼叫端（見第 2 段），
--      所以這裡不是「欄位級收斂」而是整個 UPDATE 面收掉。
--   3. DELETE 原樣保留——它就是 owner 撤銷邀請碼的路徑，而且只減不增（見第 3 段）。
--
-- 不受影響的路徑（以表擁有者 postgres 身分執行的 SECURITY DEFINER 函式，本來就不經過
-- RLS 與 authenticated 的 grant；invites 沒有 FORCE ROW LEVEL SECURITY）：
--   - public.create_invite()：本檔要保留的那條唯一寫入路徑。
--   - public.request_join()：`update public.invites set used_count = used_count + 1`。
--     這一句是 LS-33 併發正確性的核心，收回 authenticated 的 UPDATE 對它沒有影響——
--     80_join_approval.sql 第 2、6、9 段全程走 request_join 並逐段斷言 used_count，
--     本檔若真的弄壞了那條路徑，那三段會先紅。
--
-- 客戶端影響：無。此刻 LittleSprout/ 底下沒有任何一處寫 invites（邀請 UI 尚未實作），
-- 所以這次收斂不需要配套的 client 改動；日後實作邀請畫面時直接呼叫 create_invite。

-- ---------------------------------------------------------------------------
-- 1. INSERT：policy 與 grant 兩層都關
--
-- 兩層都要做，理由同 LS-33 第 6 段：policy 是下一個 migration 可能改鬆的東西，
-- grant 是另一份獨立的資料，兩層都壞掉才會破。
--
-- 這裡用 DROP POLICY，而 LS-33 對 family_members_insert 用的是
-- `alter policy ... with check (false)`——刻意的不一致，理由要留在案：
--   - LS-33 選 ALTER 的理由是「policy 物件與名字留著，日後 \d 看到的是『明確關閉』
--     而不是『不見了』」。那個顧慮是對的，但它保護的其實是**可發現性**，不是 policy
--     本身；而可發現性用 `comment on table`（見第 4 段）交代得更完整，也不會留下一條
--     永遠不可能通過、卻長得像一條真 policy 的東西在 pg_policies 裡。
--   - RLS 是預設拒絕：沒有 INSERT policy ＝ 不通過，與 WITH CHECK (false) 等效。
--   - 代價是本檔會觸發 CI 的破壞性 migration 偵測器（DROP POLICY），需要使用者本人在
--     PR body 蓋 DESTRUCTIVE-APPROVED。這是預期中的、也是這道 gate 該有的行為：
--     「拆掉一條 policy」本來就該有人看過才進得去。
-- 兩種寫法都能達成收斂；這個分歧與理由一併寫進 handoff，由 orchestrator 決定日後
-- 是否要把兩處統一成同一種形狀（統一與否都不影響安全性）。
-- ---------------------------------------------------------------------------
drop policy invites_insert on public.invites;

-- ---------------------------------------------------------------------------
-- 2. UPDATE：policy 與 grant 兩層都關（不是欄位級收斂——沒有欄位可以留）
--
-- 本票要求「一併裁量 UPDATE 面：owner 撤銷邀請走什麼路」。裁量過程與結論：
--
-- a) LS-33 落地的 RPC 一共 7 支——create_invite／request_join／approve_join／
--    reject_join／withdraw_join／list_join_requests／get_my_join_request。
--    **沒有 revoke_invite**。所以「撤銷」目前不是 RPC 路徑。
--
-- b) invites 表也沒有任何撤銷用的欄位。全部欄位是：
--    id／family_id／code／role／created_by／max_uses／used_count／expires_at。
--    沒有 revoked_at、沒有 status。所以「UPDATE 只准動撤銷相關欄位」的那個欄位集合
--    是空集合——這裡沒有 family_members 那種「role／can_upload 該留下」的正向需求。
--
-- c) 反過來看每一欄為什麼都不能給：
--    - code／expires_at／max_uses：create_invite 的三道邊界就寫在這三欄上。UPDATE 開著
--      等於 INSERT 沒關——先用 RPC 產一支合規的碼，再 UPDATE 成 100 年後到期、可用十萬次。
--    - used_count：**絕對不能讓呼叫端可寫**。它是 request_join 併發正確性的根
--      （FOR NO KEY UPDATE 重讀 + invites_uses_within_max 這條 CHECK 兜底）。可寫的話，
--      一支用罄的碼隨時可以被歸零，max_uses 從「用完就失效」變成一個裝飾。
--    - role：approve_join 是在**核准的那一刻**才讀 invites.role 決定新成員的角色
--      （見 LS-33 approve_join 的子查詢）。可改的話，一筆已經送出的 member 申請可以在
--      owner 按下核准之前被改成 owner——申請人同意的與實際發生的不是同一件事。
--    - id／family_id／created_by：這一列是誰的、屬於哪一家、誰開的，是身分不是狀態。
--      改 family_id 更是直接把一支碼搬到另一個家庭。
--
-- d) 於是撤銷邀請的路徑就是 DELETE（第 3 段），UPDATE 面整個收掉。
--    日後若要做「軟撤銷」（保留稽核紀錄、UI 顯示已撤銷的碼），正確作法是加一支
--    revoke_invite RPC 或加一個 revoked_at 欄位＋欄位級 grant，不是把整個 UPDATE 打開。
-- ---------------------------------------------------------------------------
drop policy invites_update on public.invites;

revoke insert, update on public.invites from authenticated;

-- ---------------------------------------------------------------------------
-- 3. SELECT 與 DELETE：原樣保留，一個字都不動
--
-- invites_select（owner 看得到自家的碼）：邀請畫面要列出自己發出去的碼與剩餘次數。
--
-- invites_delete（owner 刪得掉自家的碼）＝ **撤銷邀請碼的路徑**，保留的理由：
--   - LS-33 本來就是這樣設計的：join_requests 對 invites 的複合外鍵是 ON DELETE CASCADE，
--     而且 LS-33 特地為此建了 join_requests_invite_idx，註解寫明「owner 撤銷（DELETE）
--     一支邀請碼時，cascade 要在這張表上找子列」。撤銷連帶讓該碼底下的待審申請一起消失，
--     正是撤銷該有的語意。
--   - 這條路徑**只減不增**：刪掉一支碼只會讓能力變少，不可能讓任何人取得他原本沒有的
--     權限。INSERT／UPDATE 之所以要關，是因為它們可以憑空造出或放寬一支碼；DELETE 沒有
--     這個性質，所以不需要為它建一支 RPC。
--   - 不退還 used_count 的問題不存在——整列都不在了。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. 表註解：把「唯一寫入路徑」寫進資料庫本身
--
-- 兩個用途：
--   a) 取代第 1 段放棄掉的那個「\d 看得到明確關閉」的性質，而且比它完整——
--      `\d+ public.invites` 會同時看到「沒有 INSERT/UPDATE policy」與「為什麼沒有」。
--   b) 20260822120200_rls_policies.sql 的兩處註解已經過時：
--        :155-157 對 family_members 說「現階段沒有 RPC，關掉會讓家庭加不了人」——
--                 LS-33 已落地並收斂該 policy。
--        :173     對 invites 說「以邀請碼加入家庭需要 SECURITY DEFINER RPC，見 Phase 1-2」——
--                 同樣已落地。
--      **那個檔案是已套用的舊 migration，不改**（改了會讓已部署環境與 repo 內容對不上，
--      且 migration 是一份歷史紀錄，不是可編輯的文件）。沿用 LS-33 的處理方式：舊註解留在
--      原地，新的事實寫在新 migration 裡；差別是這次多寫進 comment on table，讓「以哪一份
--      為準」在資料庫裡直接查得到，不必先知道要去翻哪一個 migration 檔。
-- ---------------------------------------------------------------------------
comment on table public.invites is
  '家庭邀請碼。唯一的寫入路徑是 public.create_invite() —— authenticated 沒有 INSERT／UPDATE 的 policy 也沒有 grant（LS-37）。'
  '碼的長度／字元集與 expires_at ≤ 30 天、max_uses 1-20 這三道邊界全部由該 RPC 保證；'
  'used_count 只由 request_join()（definer）加一，是併發正確性的根，任何呼叫端可寫的路徑都不得存在。'
  'owner 撤銷邀請＝DELETE 該列（cascade 掉其下的 join_requests）。'
  '註：20260822120200_rls_policies.sql:173 那句「見 Phase 1-2」的前瞻註解已過時，以本說明為準。';
