# API.md — Little Sprout 後端契約（iOS 呼叫端視角）

> **這份文件是給 ios-dev 寫 client 程式碼時查的，不是給 DBA 看 schema 的。**
> 契約的真身是 `supabase/migrations/*.sql`（PostgREST 自動生成 + SECURITY DEFINER RPC）；
> 這份文件是從 migrations **機械抽出**（RPC 簽章、表清單）後**人工補上語意**（誰能呼叫、
> 副作用、併發語意、錯誤碼意義）的單一可消費版本。
>
> **不是凍結，是契約成品化＋機械對帳**（LS-41）：本專案 UI 尚未實作，硬凍結沒有要保護的
> 消費者；真實風險是 agent 用猜的（RPC 名／參數／錯誤碼語意）實作 UI 而不讀 migrations。
> 對帳規則：**任何 PR 改了 `supabase/migrations/` 或這份文件，`scripts/gates/api-contract-check.sh`
> 會比對本檔最下方「機械對帳清單」與 migrations 抽出的 RPC 簽章／表清單，兩邊沒有完全對上
> 就是紅燈**（改 schema 忘了同步這份文件、或這份文件寫了不存在的 RPC，都會被擋）。細節見
> `docs/COLLABORATION.md` §7。
>
> **這份文件涵蓋的分支狀態**：以 `development` 分支當下的 migrations 為準（含 LS-6／LS-15／
> LS-33／LS-36／LS-37／LS-40／LS-48／LS-52／LS-58）。

## 目錄

1. [連線基礎](#1-連線基礎)
2. [資料表讀寫路徑總覽](#2-資料表讀寫路徑總覽)
3. [逐表細節](#3-逐表細節)
4. [RPC 逐支文件](#4-rpc-逐支文件)
5. [錯誤碼全表](#5-錯誤碼全表)
6. [Storage：media bucket 與路徑規約](#6-storagemedia-bucket-與路徑規約)
7. [邀請／加入／核准狀態機](#7-邀請加入核准狀態機)
8. [多寶貝約束（children 一對多）](#8-多寶貝約束children-一對多)
9. [機械對帳清單（gate 讀取，勿手動改格式）](#9-機械對帳清單gate-讀取勿手動改格式)

---

## 1. 連線基礎

- 後端＝Supabase：Postgres（PostgREST 自動生成 REST）＋ Auth ＋ Storage。iOS 端用
  `supabase-swift`，不要手刻 HTTP 呼叫。
- 所有資料表與 RPC 都在 `public` schema（`supabase/config.toml` 的 `api.schemas` 只暴露
  `public`／`graphql_public`）；`private` schema 的函式**不對外**，client 永遠呼叫不到，
  不需要也不應該嘗試。
- 認證：Supabase Auth（Sign in with Apple／Email OTP，LS-17）。所有表與 RPC 的權限判斷
  一律吃 `auth.uid()`（登入後的 JWT `sub`），未登入呼叫任何一支表或 RPC 都會被 RLS／
  RPC 內部檢查擋下（`42501`）。
- **沒有 `anon` 角色的資料存取**：`anon` 對 16＋1 張表與全部 12 支 RPC 都沒有任何權限
  （逐表逐支 revoke，見 `supabase/migrations/20260822120000_init_schema.sql` 檔尾與
  `supabase/tests/60_default_privileges.sql`）。App 內任何畫面都必須先完成登入才能打
  API，沒有「訪客瀏覽」路徑。
- Base URL／anon key：從 `Secrets.xcconfig`（gitignored）讀，不寫進這份文件，也不寫死在
  程式碼裡。

---

## 2. 資料表讀寫路徑總覽

**判斷一張表「能不能直接 `.from("table").insert(...)`」的原則**：看該表在 migrations 裡
對 `authenticated` 的 **table/column grant** 還在不在，RLS policy 只是第二道門——grant
先被收回的表，就算 policy 看起來允許，PostgREST 也會在到達 policy 之前先被 `42501`
擋下（先 grant 後 policy 是兩層獨立防線，這份文件也按這個順序解讀每一張表）。

| 表 | 讀 | 新增 | 修改 | 刪除 | 備註 |
|---|---|---|---|---|---|
| `profiles` | 同家庭成員互看 | 自己（登入時建立） | 僅自己 | ❌ 無 delete policy | 帳號刪除走 Auth 側 cascade |
| `families` | 我所屬的家庭 | 任何登入者（自建家庭） | `name`／`require_approval` 兩欄，owner-only | ❌ 無 delete policy | `storage_quota_bytes`／`storage_used_bytes` 兩個額度欄位永遠唯讀——不論身分，client 都改不動（只有 `media` 表的 trigger 與 `service_role` 能寫） |
| `family_members` | 我所屬家庭的成員 | 🔒 **RPC-only**（`request_join`／`approve_join`，直接 INSERT 已被 revoke） | 僅 `role`／`can_upload` 兩欄，owner-only | owner 移除任何人；任何人可自行退出 | LS-33/LS-6 收斂：不存在「owner 直接把任意 user_id 塞進成員名單」的路徑 |
| `invites` | owner 看自家的邀請碼 | 🔒 **RPC-only**（`create_invite`，直接 INSERT 已被 revoke） | 🔒 **無 UPDATE 路徑**（policy 與 grant 兩層都關，LS-37） | owner 撤銷（DELETE，cascade 掉底下的 pending 申請） | 撤銷邀請碼＝DELETE 該列，沒有「軟撤銷」欄位 |
| `children` | 我所屬家庭的孩子 | owner-only | owner-only | owner-only | Member/Viewer 唯讀 |
| `media` | 我所屬家庭的檔案中繼資料 | 有上傳權者（`uploaded_by` 必須是自己） | 僅 `taken_at`／`deleted_at`／`width`／`height` 四欄；owner 任意列，上傳者僅自己上傳的**且當下仍有上傳權** | 硬刪僅 owner（一般刪除走 `deleted_at`） | `byte_size`／`storage_path`／`family_id`／`uploaded_by` 一旦寫入不可改；`can_upload` 被 owner 關掉後，非 owner 的原上傳者連軟刪除自己的照片都會被拒（`42501`），見 §3 |
| `albums` | 我所屬家庭的相簿 | owner／member（`created_by` 必須是自己） | 🔀 **混合模式（LS-52）**：內容（title／child_id／cover_media_id）僅建立者本人直接 `.update()`；軟刪／還原（`deleted_at`）建立者自己的可直接 `.update()`，owner 對別人相簿僅能用 `set_album_deleted` RPC | owner-only | Viewer 不可建立相簿；owner 對別人相簿的內容**沒有**直接 `.update()` 路徑——見 §3「為什麼 albums／comments／diaries 用了三套不同的寫入模型」 |
| `album_media` | 同上 | owner／member | owner／member | owner／member | 連結表自帶 `family_id`，policy 不必 join 回 `albums` |
| `diaries` | 我所屬家庭的日記 | 🔒 **RPC-only**（`create_diary_entry`，直接 INSERT 已被 revoke） | 🔒 **RPC-only**：內容（body／entry_date／child_id）僅作者本人用 `update_diary_entry`；軟刪／還原（`deleted_at`）作者自己的或 owner 任何一篇，皆用 `set_diary_deleted`（直接 UPDATE 已被 revoke） | owner-only（硬刪，policy 未變） | LS-48 收斂：owner 不能像 `albums` 那樣直接改寫別人日記的內容，只能移除 |
| `diary_media` | 同上 | owner／member | owner／member | owner／member | 同 `album_media` |
| `comments` | 我所屬家庭 | 🔒 **RPC-only**（`create_comment`，直接 INSERT 已被 revoke） | 🔒 **RPC-only**：內容（`body`）僅作者本人用 `update_comment`；軟刪／還原（`deleted_at`）作者自己的或 owner 任何一則，皆用 `set_comment_deleted`（直接 UPDATE 已被 revoke） | owner-only（硬刪，policy 未變） | LS-58 收斂：取代 LS-52 的 hybrid 模式，理由與 `diaries` 同型（見 §3「為什麼 albums／comments／diaries 用了三套不同的寫入模型」）；Viewer 仍能呼叫 `create_comment`／`update_comment`，符合 PLAN §3 |
| `reactions` | 我所屬家庭 | 🔒 **RPC-only**（`toggle_reaction`，直接 INSERT 已被 revoke） | ❌ 無 update policy（沒有可改的內容欄位） | 🔒 **RPC-only**（`toggle_reaction`，直接 DELETE 已被 revoke） | LS-58：加入／收回都收斂進 `toggle_reaction`，不再需要呼叫端自己處理 `23505`（見 §4） |
| `device_tokens` | 僅自己的裝置 | ⚠️ 見下方 | 僅自己 | 僅自己 | **換裝置／換帳號登入請務必呼叫 `register_device_token` RPC，不要直接 INSERT／UPSERT**（見 §4） |
| `feed_items` | 我所屬家庭的時間軸 | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | 沒有任何 client 可寫入的路徑，連 grant 都沒有；混排查詢建議走 `get_family_timeline` RPC（見 §4），不要直接 `.from("feed_items")` 拼 keyset 條件 |
| `content_reports` | 自己送出的＋（若是 owner）自家的 | **任何家庭成員** | 僅 `status` 欄，owner-only，且只能改成 `resolved`（不能 `dismissed`） | ❌ 無 delete policy | 駁回（`dismissed`）保留給平台方用 `service_role`／Dashboard 處理 |
| `blocked_users` | 僅自己封鎖的名單（`blocker_id = 我`） | 僅自己 | ❌ 無 update policy | 僅自己 | 被封鎖者看不到自己被封鎖 |
| `join_requests` | 自己送出的申請＋（若是 owner）自家的待審申請 | 🔒 **RPC-only**（`request_join`） | 🔒 **RPC-only**（`approve_join`／`reject_join`／`withdraw_join`） | 🔒 無 delete policy | 沒有任何 client 直接寫入路徑，grant 只有 SELECT |
| `notification_events` | 🔒 **完全不可讀**（成員無 grant 也無 policy） | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | LS-58：推播彙總佇列的資料面，只給 `service_role`（LS-22 的 Edge Function）讀寫；見 §3 |

**寫入路徑小結（給 iOS 呼叫端的心智模型）**：`family_members`／`invites`／`join_requests`／
`diaries`／`comments`／`reactions` 六張表**完全不能**用 `.insert()`／`.update()`／
`.delete()`（`family_members` 的 `role`／`can_upload` 例外，見上表；`diaries`／`comments`
的硬刪 `.delete()` 仍走 policy 直接允許，見上表），一律呼叫對應 RPC；其餘表可用
PostgREST 的 `.from(...)` 直接讀寫，但每張表都有欄位級或列級限制，寫超出範圍會拿到
`42501`（grant 層）或該欄位的 `CHECK`/`NOT NULL` 違反碼（policy 通過但值不合法）。

**例外（LS-52，僅 `albums` 適用）：owner 越權 `.update()` 不會回 `42501`，而是靜默影響
0 列**——`albums_update` 的 USING 子句只有「建立者本人」這一個分支，owner 對別人的
相簿下 `.update()` 時，那一列根本不在 USING 比對得到的範圍內，Postgres 對「比對不上
USING 的列」的標準反應是直接排除、不觸發任何錯誤（跟對一個不存在的 `id` 下 `.update()`
一樣，`PATCH` 回應是 200 但 body 是空陣列，不是 4xx）。這**不是** grant 層限制（不會有
`42501`），也不是 `CHECK` 違反（不會有 `23514`）——呼叫端必須自己檢查回傳的受影響列數／
`return=representation` 的內容判斷「這次 `.update()` 到底改到了沒有」，不能假設
「沒有丟出錯誤＝改到了」。owner 想對別人的相簿做事，唯一有意義的操作是移除／還原，
要呼叫 `set_album_deleted` RPC（見 §4）——這支呼叫失敗時**會**丟出明確的 `42501`／
`LS023`，不會有「靜默 0 列」這種模稜兩可的結果。**`comments` 不再適用這條例外**：
LS-58 把 `comments` 的寫入面整個收斂成 RPC-only（同 `diaries`），直接 `.update()` 對
任何人（含作者本人）都會回 `42501`，不會有靜默 0 列的情況；`set_comment_deleted` 對
失敗情境的保證與 `set_album_deleted` 相同。

---

## 3. 逐表細節

以下只列**呼叫端會直接用到**的欄位語意；完整欄位型別以 `supabase/migrations/20260822120000_init_schema.sql`
與 `20260823010000_join_approval.sql` 為準。

### `profiles`
- `id`＝`auth.users.id`（登入後自動存在，不必自己建立列——若尚未存在，登入流程要先
  `insert` 一列，`display_name` 必填、1–50 字）。
- 只看得到：自己 ＋ 與自己同家庭的人（`private.peer_profile_ids()`）。陌生使用者的
  `display_name`／`avatar_url` 不會外洩。

### `families`
- `storage_quota_bytes`／`storage_used_bytes`：**唯讀**，client 完全看不到自己能改的欄位
  以外的東西被寫入——這兩欄只由 `media` 表的 trigger（`private.media_storage_sync`）與
  `service_role` 維護。額度用完時不是查這兩欄比大小，是等 `media` 的 INSERT/UPDATE
  回傳 `LS002`。
- `require_approval`（LS-33）：`true`＝邀請碼申請需 owner 核准（新家庭預設值）；
  `false`＝驗碼通過即直接入家。只有 owner 能改（`update (require_approval)`）。
- **建立家庭**：`insert into families (name, created_by)`，`created_by` 必須是自己
  （`auth.uid()`）。DB trigger 會自動把建立者寫成第一位 owner——不需要，也不能，額外自己
  `insert` 一列 `family_members`。這條路徑對任何登入者開放（PLAN §9-C5：陌生人下載
  app 後必須能自建家庭）。

### `family_members`
- 加入家庭的唯一路徑是 `request_join` RPC（見 §4／§7），owner 審核走 `approve_join`；
  **不存在**「owner 直接 `insert` 一列把任意 user_id 塞進來」的路徑（LS-33 收斂）。
- Owner 只能改 `role`（升降）與 `can_upload`（逐人開關上傳），不能改 `user_id`／
  `family_id`（防止「把既有列的歸屬改寫成陌生人」這條側門，LS-33 §6b）。
- `family_members.can_upload`：預設 `true`（member 預設可上傳）。owner 才有的欄位。
- 移除成員／自行退出都走 `DELETE`。**最後一位 owner 無法被移除或降級**——DB trigger
  （`private.enforce_family_has_owner`）會擋下並回傳 `LS001`；要先把另一人升為 owner。

### `invites`
- 產碼只能呼叫 `create_invite` RPC；**沒有 UPDATE 路徑**，撤銷邀請碼＝`DELETE`
  該列（會 cascade 掉底下所有 pending 的 `join_requests`）。
- `code`：8 碼、大寫、字元集 `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（拿掉 `0/O/1/I`）。
- `max_uses`／`used_count`：次數在「申請成立」（`request_join` 呼叫成功）時就消耗，
  **不是**核准時才扣；拒絕／撤回不退還次數。

### `children`
- `family_id, id` 有複合 UNIQUE，供 `albums`/`diaries` 的複合外鍵綁定同家庭。
- 一個 family 可以有多個 children（1 家庭 : N 孩子），見 §8。
- 只有 owner 能建立／編輯／刪除；member／viewer 唯讀。

### `media`
- `storage_path` 必須符合 `{family_id}/{yyyy}/{mm}/{media_id}.{ext}`（見 §6），且有
  `CHECK` 強制前綴＝`family_id`。
- **上傳流程順序很重要**：Storage 物件與 `media` 列是兩份獨立資料，DB 不會替你保證兩者
  一致。正確順序：① 先把檔案 PUT 進 Storage（`storage.objects`，見 §6）② 成功後才
  `insert` 對應的 `media` 列。若第②步因 `LS002`（額度爆了）或其他原因失敗，**已經上傳
  的 Storage 物件會變成孤兒**——上傳者對自己剛上傳的物件有 Storage `DELETE` 權限
  （見 §6），失敗時 client 自己要清掉，DB 不會幫你清。
- `byte_size` 是 `families.storage_used_bytes` 額度計算的唯一依據（`media` 表的
  statement-level trigger 依 `byte_size` 加總），**不是**看 Storage 物件實際大小。
  這代表：如果 client 上傳到 Storage 的檔案大小與 `media.byte_size` 填的值不一致，
  額度計算會跟著算錯——`byte_size` 必須填實際上傳的位元組數。
- soft delete（`deleted_at`）立刻釋放額度；硬刪只有 owner 能做。
- **`media_update` policy 的上傳者分支判斷「當下」而不是「上傳當時」是否有上傳權**
  （`family_id in uploadable_family_ids()`，跟 §6 storage.objects 的規則同一個判準）：
  owner 把某個 member 的 `can_upload` 關掉之後，那個人（若不是 owner）連軟刪除
  （`update ... set deleted_at = now()`）自己以前上傳的照片都會被拒，拿到 `42501`
  ——不是「刪不到別人的」，是「刪不到自己的」。想清掉自己上傳的內容，要嘛先請 owner
  恢復 `can_upload`，要嘛請 owner 出手處理（owner 分支不受這個限制）。

### `albums` / `diaries`
- `child_id` 可為 `NULL`（家庭共用內容，不特別掛在某個孩子底下）；非 NULL 時必須是
  同一家庭的孩子（複合外鍵，見 §8）。
- `albums`（LS-52 起，見 §2 表與下方「三套寫入模型」）：
  - 內容（title／child_id／cover_media_id）僅建立者本人（仍是該家庭 owner/member）
    直接 `.update()`；owner 對別人建立的相簿**沒有**改寫內容的路徑（連「靜默 0 列」
    都沒有其他分支可用，見 §2「寫入路徑小結」的例外說明）。
  - 軟刪／還原（`deleted_at`）：建立者可直接 `.update()` 自己的（要求仍是
    owner/member）；owner 對別人的相簿要呼叫 `set_album_deleted` RPC（見 §4）。
    **建立者也可以改用這支 RPC 軟刪／還原自己的相簿**，且授權範圍比直接
    `.update()` 寬——只要求仍是該家庭任一角色的成員，被降級成 viewer 也適用
    （F5：對齊 `diaries`／`comments` 的同名 RPC，見 §4）。
  - 硬刪（真正 `DELETE` 整列）仍是 owner-only 的直接 policy，未被收斂進 RPC。
- `diaries`（LS-48 起，見 §2 表與 §4 三支 RPC）：
  - 新增／編輯內容／軟刪都是 **RPC-only**，直接 `.insert()`／`.update()` 一律 `42501`
    （這點與 `albums` 不同：`albums` 的作者仍保留直接 `.update()` 路徑，見上方）。
    `comments` 自 LS-58 起也是這個模式，見 §3「comments / reactions」段。
  - Owner 對別人日記**只有軟刪權**（`set_diary_deleted`），**沒有**編輯內容的權限。
  - 硬刪（真正 `DELETE` 整列）仍是 owner-only 的直接 policy，未被收斂進 RPC。

**為什麼 `albums`／`comments`／`diaries` 曾經、現在用了不同的寫入模型**：`comments`
自 LS-58 起已經改用跟 `diaries` 相同的 RPC-only 模式，取代 LS-52 當時採用的 hybrid
模式——這裡完整記錄演進過程與取捨，而不是只留最終狀態，因為「為什麼 albums 現在還是
hybrid、comments 不是」這個問題如果只看 schema 本身看不出來，得知道 comments 曾經也是
hybrid 才看得懂 albums 為什麼沒有跟著一起改：

1. **`media`（單一允許欄位集合，見上方 `media` 段）**：owner 分支與上傳者分支雖然是
   兩條 USING 分支，但兩邊允許改的欄位集合本來就相同（`taken_at`／`deleted_at`／
   `width`／`height`），跟「這一列是不是我建立的」無關，所以純粹用 column-level
   grant（角色層級、不分列）就能表達，不需要 RPC。
2. **`diaries`（RPC-only，LS-48）／`comments`（RPC-only，LS-58）**：`diaries_update`
   policy 原本讓 owner 能改寫別人日記的**任意欄位**（不只 `deleted_at`），超出
   PLAN §10「Owner 移除內容」授權的範圍。LS-48 修法把 `diaries` 的 INSERT／UPDATE
   整個收斂成三支 RPC，直接寫入的 grant 也一併 revoke。LS-52 當時修 `comments`／
   `albums` 同一種洞（見下一點的 hybrid 說明）；LS-58 為了新增
   `create_comment`／`update_comment` 這兩支寫入 RPC（給留言分頁讀取＋推播彙總
   trigger 一個單一、可稽核的寫入入口），順勢把 `comments` 也整個收斂成 RPC-only，
   取代 LS-52 的 hybrid——但**只收斂 comments，不動 albums**（見下一點）：這是本票
   刻意的範圍控制，不是「反正都要動就一起改」，albums 沒有出現任何要求它跟著一起
   收斂的新需求（沒有 list_albums 這類新 RPC 要建），維持 LS-52 當時的裁量。
3. **`albums`（hybrid 模式，LS-52，至今未變）**：跟 `diaries`／`comments` 是同一種洞
   （owner 分支不限欄位），但 LS-52 修法**沒有**照抄「整表收斂成 RPC-only」：這個洞
   只出在 owner 分支，建立者改自己內容的那個分支本來就沒有問題，收斂範圍只動 owner
   分支，建立者的直接 `.update()` 路徑與 grant 都原封不動——`set_album_deleted` 只
   服務 owner 對別人相簿的軟刪／還原，不像 `diaries`／`comments` 的 RPC 服務了新增
   與編輯。曾經考慮過比照 `families`／`content_reports` 用 column-level grant 收斂
   （欄位級 grant 是角色層級、不分列，只有在「不論走 owner 分支還是作者分支，允許改
   的欄位集合都一樣」時才適用，`media` 正是這種形狀）；但 `albums` 的兩個分支允許的
   欄位集合本來就該不同（作者能動全部內容欄位，owner 只能動 `deleted_at`），
   column-level grant 對同一個角色（`authenticated`）物理上表達不出「依這一列是不是
   我建立的，給不同欄位集合」，這條路走不通，改採 RPC，理由與取捨細節見
   `supabase/migrations/20260825010000_albums_comments_owner_scope.sql` 檔頭（該檔
   也是當時 `comments` 尚未收斂前的 hybrid 實作，供對照演進脈絡）。

**曾經考慮過、後來否決的第四種寫法**：在 RLS 的 WITH CHECK 裡直接對同一張表寫自我
join 子查詢，比對「這一欄的新值是不是跟改之前一樣」——本機用 Supabase CLI 映像
（PostgreSQL 17.6）實測：不包 SECURITY DEFINER 直接自我 join 會被 Postgres 判定
`42P17 infinite recursion detected in policy`（連合法的 `deleted_at`-only 更新也一起
擋下）；包一層 SECURITY DEFINER 函式繞過遞迴之後**確實可行**，owner 竄改內容會被
WITH CHECK 擋下並噴出真正的 `42501`。沒有採用，是因為這種寫法要求 WITH CHECK 逐欄
列舉「除了 `deleted_at` 以外每一欄都要跟舊值一樣」，日後這兩張表加新欄位時容易被
忘記同步更新、悄悄重新打開同一種洞；RPC 版本「函式裡的 UPDATE 只 SET 一欄」是由
程式碼形狀保證，不靠列舉維護，對 schema 演進更安全。

### `album_media` / `diary_media`
- 純連結表，自帶 `family_id`（不必 join 回 `albums`/`diaries` 判斷歸屬）。
- 兩條複合外鍵確保「A 家的相簿掛 B 家的照片」在 DB 層建不起來，不只是 RLS 擋。
- 同一張 `media` 可以同時出現在多個相簿／日記裡（沒有「一張照片只能屬於一個相簿」的
  約束）。

### `comments` / `reactions`
- `target_type` ∈ `album|media|diary|comment`，`target_id` 是對應表的 `id`。**這是
  多型關聯，DB 無法對它下外鍵**——傳一個完全不存在的 `target_id`（誰都沒建過）不會被
  DB 擋下（沒有 `23503` 可用），孤兒留言的清理是應用層或定期清理的責任，不是 API 的
  錯誤處理範圍，`create_comment`／`toggle_reaction`（見 §4）對這種情況維持既有裁量、
  照樣放行。**但 `target_id` 若真的存在、卻屬於別的家庭，這兩支 RPC 會擋下（`LS026`，
  LS-58 R1）**——只驗證「查得到的話 family 對不對」，不驗證「查得到查不到」，這是刻意
  縮小的修補範圍（見 §4 兩支 RPC 各自的說明）。
- `comments`（LS-58，取代 LS-52 的 hybrid 模式，見 §2 表與上方「三套寫入模型」）：
  新增／編輯內容／軟刪都是 **RPC-only**，直接 `.insert()`／`.update()` 一律 `42501`
  （這點現在跟 `diaries` 一致；跟收斂前的 LS-52 不同，那時作者仍保留直接 `.update()`
  路徑）。`create_comment`／`update_comment` 的授權範圍**刻意延續 LS-52 定案的判準、
  沒有比照 diaries 收緊**：任何角色（含 viewer）都能呼叫 `create_comment`；
  `update_comment` 的作者分支只要求「當下仍是該家庭**任一角色**的成員」，不要求
  owner/member——因為留言的作者分支從 `comments_update` policy 一開始就沒有排除
  viewer（PLAN §3：Viewer 也能留言），這是延續既有、已被記錄在案的產品決定，不是
  LS-58 的新裁量。`update_comment` 也**刻意不檢查目標是否已軟刪除**（跟
  `update_diary_entry` 不同）——已軟刪除的留言仍可編輯，因為收斂前的 `comments_update`
  policy 從來沒有這條限制，`albums_update` 的作者分支現在也還是沒有，這不是要通用套用
  到每張表的規則，是 `diaries` 自己的產品決定。owner 對別人留言的軟刪／還原要呼叫
  `set_comment_deleted` RPC（見 §4，LS-52 建立、本票未改動），對內容沒有任何直接寫入
  路徑。
- `reactions`（LS-58）：加入／收回都收斂進 `toggle_reaction` RPC（見 §4），直接
  `.insert()`／`.delete()` 一律 `42501`。呼叫端**不再需要**自己處理
  `UNIQUE(target_type, target_id, user_id)` 的 `23505`——`toggle_reaction` 內部用
  advisory lock 序列化「查詢現況→決定加或刪」，永遠回傳布林值（`true`＝加入、
  `false`＝收回），不會噴 `23505`。**唯一鍵不含 `family_id`**（`UNIQUE(target_type,
  target_id, user_id)`，跟表定義一致），但**加入與收回兩條路徑都受 `LS026` 約束**
  （merge-reviewer PR #85 R2 F2 實測澄清，修正 R1 對殘餘範圍的高估）——`LS026`
  的目標歸屬檢查排在 `DELETE`／`INSERT` 之前：對**真的存在**的 target，呼叫端用
  跟先前不同的 `p_family_id` 想收回別的家庭底下的反應，會直接拿到 `LS026`，
  `DELETE` 完全不會執行，那個家庭的反應原封不動。殘餘情況只剩 `target_id`
  **完全查不到**（孤兒，`private.target_family_id` 回 `NULL`）時——這時 `LS026`
  檢查放行，`DELETE` 才會單靠 `user_id` 找到並收回呼叫者對這個孤兒 id 的反應，
  不論那顆反應當初是用哪個 `family_id` 加的；這是孤兒 `target_id` 既有裁量（放行、
  不驗證存在）的自然延伸，不是新的洞，只影響呼叫者自己的反應，不是越權。

### `device_tokens`
- **不要**直接 `.upsert()` 或 `.insert()`／`.delete()` 這張表。同一支裝置換帳號登入時，
  三條直接路徑都走不通（見 §4 `register_device_token` 的說明），會留下跨帳號的推播
  外洩風險。**永遠透過 `register_device_token` RPC**。

### `feed_items`
- 純唯讀，`kind ∈ album|media|diary`，`occurred_at` 依 kind 各自取（album 用
  `created_at`；media 用 `coalesce(taken_at, created_at)`；diary 用 `entry_date`
  轉 UTC 午夜）。分頁用 keyset：`WHERE family_id = ? AND (occurred_at, ref_id) < (?, ?)
  ORDER BY occurred_at DESC, ref_id DESC LIMIT n`，不要用 `OFFSET`。
- **不要直接 `.from("feed_items")` 拼上面那條查詢**——用 §4 的 `get_family_timeline`
  RPC。它就是這條查詢包成 RPC 的結果，額外做了 `p_limit` 邊界夾定（見 §4），且是唯一
  暴露 `child_id`（LS-48 新增欄位）篩選能力的入口。
- `child_id`（LS-48）：`diary`／`album` 由對應資料列的 `child_id` 帶入；**`media`
  恆為 `NULL`**——`media` 本身沒有 `child_id` 欄位，只能透過 `album_media` 間接、
  多對多地關聯到相簿的 `child_id`，無法唯一決定歸屬。實際影響：`get_family_timeline`
  的 `p_child_id` 篩選為指定值時，`media` 類項目**不會出現**；只有 `p_child_id = NULL`
  （查全部）時才看得到。

### `notification_events`
- **推播彙總佇列的資料面（LS-58），只做資料層，不含發送**——發送邏輯（挑出待送事件、
  決定通知對象、呼叫 APNs）是 LS-22 的 Edge Function 範圍，不在這份 API 契約內。
  記在這裡是給 LS-22 開發時查表結構與彙總規則用，**iOS client 完全不會呼叫這張表**
  （沒有任何 grant，見下）。
- 來源：`comments`／`reactions`／`diaries`／`albums` 四張表各自的 `AFTER INSERT`
  trigger，只在**新增**時觸發（留言/按讚的收回、日記/相簿的編輯或軟刪都不通知）。
- 欄位：`kind`（`comment`/`reaction`/`diary`/`album`）＋`target_type`／`target_id`
  （`comment`／`reaction` 指向被留言／被按讚的目標；`diary`／`album` 指向內容自己）＋
  `actor_id`（最近一次觸發者）＋`event_count`（彙總筆數）＋`occurred_at`（最近一次
  事件時間）＋`sent_at`（`NULL`＝待送，由 Edge Function／`service_role` 標記已送出）。
- **彙總策略**：同一 `family_id`＋`kind`＋`target_type`＋`target_id` 在 **5 分鐘滾動
  視窗**內的多次事件合併成同一筆（`event_count` 累加、`occurred_at` 更新成最新一次、
  `actor_id` 換成最新觸發者）——只要事件間隔小於 5 分鐘就持續延伸同一筆，不是從第一次
  事件起算的固定桶。合併判斷由 `pg_advisory_xact_lock` 序列化，避免兩個幾乎同時發生的
  事件都判斷成「還沒有可合併的視窗」而各自開一筆。**合併鍵含 `family_id`（LS-58 R1）**
  ——`target_type`／`target_id` 是多型關聯、沒有 FK（見上方「已知代價」），不能只靠
  `(kind, target_type, target_id)` 當合併鍵：這會讓兩個不同家庭對同一個 `target_id`
  （例如被踢出的前成員手上還記得的舊 id）的事件合併成一列，通知因此被算進錯的家庭。
  `create_comment`／`toggle_reaction`（§4）已經在寫入前擋掉「target 存在但屬於別家」
  （`LS026`），合併鍵含 `family_id` 是第二道防線。
- **權限：成員完全讀不到**——沒有 RLS policy（`enable row level security` 但零 policy），
  也沒有任何 table grant 給 `authenticated`／`anon`；PostgREST 會在到達 RLS 之前就先被
  grant 層擋下（`42501`）。`service_role`（LS-22 的 Edge Function 用）明確 grant 了
  `SELECT`／`UPDATE`（讀待送事件、標記 `sent_at`）——**不要假設平台預設會給
  service_role 足夠的權限**：本 repo 實測過 public schema 新表對 `service_role` 的
  預設只有 `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN`，沒有 `SELECT`/`UPDATE`，這張
  表的 migration 自己明確 grant 這兩項（比照
  `20260822120300_harden_default_privileges.sql` §2 對 sequences 的既有作法）。
  `INSERT`／`DELETE` 都沒有給 `service_role`——寫入只走 trigger，刪除留給日後的
  retention 策略決定（目前沒有任何清理路徑，已送出的列會一直留著，見該 migration
  檔尾備註）。

### `content_reports` / `blocked_users`
- `content_reports`：任何家庭成員都能送出檢舉（`reporter_id` 必須是自己）；owner 只能
  把 `status` 改成 `resolved`（無法 `dismissed`——那是平台方的權限，走 `service_role`／
  Dashboard，不在這份 API 契約範圍內）。
- `blocked_users`：被封鎖者**看不到**自己被封鎖（policy 只讓 `blocker_id = 我` 的人
  讀寫），UI 不要試圖查「誰封鎖了我」。

### `join_requests`
- 完全沒有直接寫入路徑（`grant` 只給了 `SELECT`），一律透過 §4 的 RPC 操作。
- Owner 想看自家待審清單、申請人想看自己申請狀態，優先用 §4 的 `list_join_requests`／
  `get_my_join_request` 兩支 RPC（比直接 `select` 這張表多拿得到對方的顯示名稱／家庭
  名稱，因為申請成立當下雙方還沒有成員關係，直接查這張表加 `profiles`/`families` 的
  join 會被 RLS 擋掉）。

---

## 4. RPC 逐支文件

呼叫方式：`supabase.rpc("函式名", params: [...])`（supabase-swift）。全部 12 支都只對
`authenticated` 開放（`anon`／`public` 已逐支 revoke，見
`supabase/tests/60_default_privileges.sql` 的正向對照）；其中 11 支是
`SECURITY DEFINER`，只有 `get_family_timeline`（LS-48）是 `security invoker`——它不需要
繞過 RLS，完全依賴 `feed_items` 既有的 RLS 做家庭隔離，見該支 RPC 的說明。

### `register_device_token(p_token text, p_platform text) -> void`
- **誰能呼叫**：任何已登入使用者。
- **用途**：註冊／接手推播裝置 token。
- **為什麼不能用直接 UPSERT**：`token` 是 PK。同一支裝置換帳號登入時：INSERT 撞
  `23505`（舊列還在）；UPSERT 的 `ON CONFLICT UPDATE` 要通過舊列的 RLS USING
  （`user_id = 我`），但舊列屬於前一個帳號，被擋 `42501`；DELETE 舊列同理也擋 `42501`。
  三條路都走不通的後果不是「不方便」，是**跨帳號通知外洩**：舊帳號的 token 綁定留在
  DB 裡，新持有者的裝置會繼續收到前一個帳號所屬家庭的推播。這支 RPC 用
  `SECURITY DEFINER` 繞過 RLS，先刪掉「別人的」那一列再插入自己的——這不是提權漏洞，
  push token 本身就是裝置持有者才拿得到的憑據。
- **參數**：`p_platform` 目前只接受 `"ios"`（cast 成 `device_platform` enum，其他值
  拿 `22P02`）。
- **錯誤碼**：未登入 → `42501`。
- **併發**：無特殊語意，單一 statement。

### `create_invite(p_family_id uuid, p_role text, p_expires_at timestamptz, p_max_uses integer) -> text`
- **誰能呼叫**：該家庭的 owner。
- **回傳**：新產生的邀請碼字串（8 碼大寫）。
- **參數邊界（RPC 是安全邊界，不是 UI 輔助，直接打 API 的人也會被擋）**：
  - `p_role`：`"owner"|"member"|"viewer"`（cast 失敗 `22P02`）。
  - `p_expires_at`：必須在「現在～現在+30 天」之間，超出 → `LS017`。
  - `p_max_uses`：必須介於 1–20，超出／NULL → `LS017`。
- **錯誤碼**：未登入 `42501`；不是該家 owner `42501`；參數不合法 `LS017`；連續 5 次
  撞碼（機率極低，代表亂數來源異常）`LS016`。
- **併發**：撞碼會自動重抽最多 5 次，對呼叫端透明。

### `request_join(p_code text) -> table(status text, request_id uuid, family_id uuid)`
- **誰能呼叫**：任何已登入使用者。
- **用途**：用邀請碼申請加入家庭。輸入會先正規化（去除非英數字元、轉大寫），所以
  `abcd-1234` 與 `ABCD1234` 效果相同。
- **回傳語意**：
  - `status = "pending"`：家庭開啟審核（`require_approval = true`），`request_id`
    是新建申請的 id，UI 顯示「等待核准」。
  - `status = "joined"`：家庭關閉審核，已直接寫入 `family_members`，`request_id`
    為 `NULL`，UI 直接導向 `family_id`。
- **錯誤碼**：未登入 `42501`；碼不存在 `LS010`；已過期 `LS011`；次數用罄 `LS012`；
  已是該家成員 `LS013`；已有一筆待審申請 `LS014`。
- **併發**：對同一支邀請碼的最後一個名額用 `FOR NO KEY UPDATE` 鎖住 `invites` 列
  排隊處理，兩人同搶最後一個名額時，其中一人會確定拿到 `LS012` 而不是裸的 DB 約束
  違反（見 `supabase/tests/concurrency/join_race_*.sql`）。**client 不需要自己重試
  搶名額**——RPC 已經序列化好了，回傳的錯誤就是最終結果。

### `approve_join(p_request_id uuid) -> void`
- **誰能呼叫**：該申請所屬家庭的 owner。
- **副作用**：把申請人寫入 `family_members`（角色取自邀請碼），並把申請標記
  `approved`。若申請人在待審期間已經用別支碼入家，不會重複寫入或覆蓋既有角色。
- **錯誤碼與檢查順序（PR #58 review F9 訂正）**：`SELECT ... FOR UPDATE` 找列 →
  找不到 `request_id` 就是 `LS015`（**這一步排在 owner 檢查之前**）；找到列之後才檢查
  呼叫者是不是該家 owner，不是就 `42501`；是 owner 才檢查狀態，非 pending 一樣是
  `LS015`。實際效果：**非 owner 可以從 `LS015`／`42501` 的差異推知某個 `request_id`
  是否存在**（先前版本這裡寫反了）——但看得到的僅止於「存在與否」，看不到申請的
  狀態（那個檢查排在 owner 檢查之後，非 owner 永遠到不了那一步）；`request_id` 是
  128-bit 隨機 UUID，實務上不可窮舉猜測，這不構成有意義的資訊洩漏。未登入另外先擋
  `42501`。
- **與 migration 檔頭註解的矛盾（LS-54 N6）**：`supabase/migrations/20260823010000_join_approval.sql`
  裡 `approve_join` 上方的註解仍寫「授權檢查排在狀態檢查之前……不會從錯誤碼的差別推敲出
  某個 request id 存不存在」——這個「不洩漏存在性」宣稱**不成立**（如上：找不到列的 `LS015`
  先於 owner 檢查的 `42501`）。依「migration 是歷史紀錄、不回頭改」原則不修舊檔，**以本文為準**。
- **併發**：對同一筆申請用 `FOR UPDATE` 鎖住，與 `reject_join` 互相排隊——同一筆申請
  被同時核准與拒絕時，後到的那邊會讀到已處理狀態，拿到 `LS015`（見
  `supabase/tests/concurrency/approve_reject_race_*.sql`）。

### `reject_join(p_request_id uuid) -> void`
- **誰能呼叫**：該申請所屬家庭的 owner。
- **副作用**：只改申請狀態為 `rejected`，**不寫任何** `family_members`。
- **錯誤碼／併發**：與 `approve_join` 相同模式。

### `withdraw_join(p_request_id uuid) -> void`
- **誰能呼叫**：申請人本人。
- **用途**：撤回自己送出的申請（僅限仍是 `pending` 的）。
- **副作用**：狀態改為 `withdrawn`。**不退還邀請碼的 `used_count`**（撤回／拒絕都不退，
  見 §7 的設計理由）。
- **錯誤碼**：未登入 `42501`；申請不存在 `LS015`；不是申請人本人 `42501`；申請已被
  處理 `LS015`。

### `list_join_requests() -> table(request_id uuid, family_id uuid, applicant_id uuid, display_name text, avatar_url text, role text, created_at timestamptz)`
- **誰能呼叫**：任何已登入使用者，但只會拿回「自己是 owner 的家庭」底下 `pending`
  的申請（授權檢查就是查詢本身的 join 條件，不是額外的權限判斷）。
- **用途**：owner 的審核佇列，**不帶 `family_id` 參數**——一個帳號可能是多個家庭的
  owner，一次拿回全部待審項目，用回傳的 `family_id` 欄位自己分組。
- **排序**：最舊的申請在前（`created_at, id`）。
- **只讀**（`language sql stable`），無寫入副作用。

### `get_my_join_request() -> table(request_id uuid, family_id uuid, family_name text, status text, created_at timestamptz, resolved_at timestamptz)`
- **誰能呼叫**：任何已登入使用者，只看得到自己送出的申請。
- **回傳規則（最多一列，順序固定）**：
  1. 有 `pending` 的申請就一定回傳 pending 那筆（等待畫面永遠優先顯示「我在等什麼」）。
  2. 沒有 pending 才回傳最近一筆已處理的（`approved`/`rejected`/`withdrawn`），讓 UI
     能顯示「你的申請已被拒絕」而不是空白畫面。
  3. 從未申請過 → 0 列（不是錯誤，是空結果）。
- **只讀**，無寫入副作用。

### `create_diary_entry(p_family_id uuid, p_child_id uuid, p_body text, p_entry_date date) -> uuid`
- **誰能呼叫**：該家庭的 owner／member（Viewer 不行，同 `albums`）。
- **回傳**：新日記的 `id`。
- **副作用**：`author_id` 恆為呼叫者本人，不接受由參數指定（防冒名，同 `media.uploaded_by`
  的既有慣例）。
- **參數**：`p_child_id` 可傳 `NULL`（家庭共用，不掛某個孩子）；非 `NULL` 時必須是同一
  家庭的孩子，否則 `23503`（複合外鍵）。`p_entry_date` 傳 `NULL` 時退回 `current_date`
  （對齊資料表原本的欄位預設值，不是「必填」）。
- **錯誤碼**：未登入 `42501`；不是該家 owner/member `42501`；`child_id` 跨家庭 `23503`；
  `body` 為空或超過 20000 字 `23514`（`CHECK` 約束，非本 RPC 自訂）。
- **併發**：無特殊語意，單一 `INSERT`。

### `update_diary_entry(p_diary_id uuid, p_body text, p_entry_date date, p_child_id uuid) -> void`
- **誰能呼叫**：**只有原作者本人，且必須現在仍是該家庭的 owner/member**——即使是該
  家庭的 owner，也不能用這支 RPC 改別人日記的內容（見 §3 `diaries` 段的心智模型
  說明）；作者若已被移出家庭、或被降級成 viewer，同樣不能再編輯自己過去寫的日記
  （merge-reviewer PR #60 review F2：`author_id` 是永遠不變的歷史欄位，不能單獨當
  授權依據）。
- **語意**：**整組替換**（PUT，不是逐欄 PATCH）——三個參數（`body`／`entry_date`／
  `child_id`）一律用傳入值覆蓋，不支援「傳 `NULL` 代表不變」。呼叫端要送出完整的期望
  狀態（例如只想改 `body`，`p_entry_date`／`p_child_id` 也要照抄原值一起傳）。
- **錯誤碼**：未登入 `42501`；日記不存在 `LS020`；不是作者本人、或雖是作者但已不是
  該家庭 owner/member `LS021`（兩種情況共用同一個碼，**排在「是否已軟刪除」之前
  檢查**——未通過授權的人，不管日記是否已被移除，一律拿到 `LS021`，不會從錯誤碼差異
  推敲出一篇不屬於自己的日記目前是否已被軟刪除，同 `approve_join` 的授權檢查排序
  慣例）；已軟刪除（`deleted_at` 非 NULL）`LS020`（要先用 `set_diary_deleted(id,
  false)` 還原才能編輯）。
- **併發**：對目標列用 `FOR UPDATE` 鎖住，單一 statement 更新；與 `set_diary_deleted`
  互相排隊（見 `supabase/tests/concurrency/diary_edit_vs_delete_*.sql`：軟刪先動，
  編輯會在解除阻塞後拿到 `LS020`；編輯先動，軟刪會在解除阻塞後正常成功，但編輯的
  內容保證先落地）。

### `set_diary_deleted(p_diary_id uuid, p_deleted boolean) -> void`
- **誰能呼叫**：作者本人（**只要求現在仍是該家庭的成員，角色不拘**——被降級成 viewer
  仍可軟刪／還原自己的日記，這點刻意比 `update_diary_entry` 寬，見 migration 對這支
  函式的裁量說明）**或**該家庭的 owner（家庭內任何一篇）。作者若已完全離開家庭
  （`family_members` 裡已經沒有這一列），這支 RPC 對他完全關閉。
- **用途**：軟刪（`p_deleted = true`）／還原（`p_deleted = false`）。**唯一能寫
  `diaries.deleted_at` 的路徑**——這支只碰這一欄，owner 分支不可能被拿來竄改內容
  （物理上不會執行到 `body`／`entry_date`／`child_id` 的 `UPDATE`）。
- **副作用**：軟刪後該篇立即從 `feed_items`／`get_family_timeline` 消失，還原後立即
  回來（既有 trigger 行為，見 `supabase/tests/40_triggers_feed_and_storage.sql`）。
- **錯誤碼**：未登入 `42501`；日記不存在 `LS020`；不是作者也不是該家 owner，或雖是
  作者但已離開家庭 `42501`。
- **併發**：對目標列用 `FOR UPDATE` 鎖住；與 `update_diary_entry` 的互斥關係見上。

### `set_album_deleted(p_album_id uuid, p_deleted boolean) -> void`
- **誰能呼叫**：建立者本人（**只要求仍是該家庭任一角色的成員**，orchestrator PR
  #70 review F5 裁決對齊 `set_diary_deleted`／`set_comment_deleted`——被降級成
  viewer 仍可移除／還原自己建立的相簿）**或**該家庭的 owner（家庭內任何一本
  相簿）。**這個要求比 `albums_update` policy 的建立者分支寬**（那支要求仍是
  owner/member，見 §3）——「改內容」與「移除／還原自己的東西」是不同性質的
  操作，前者是持續的創作權，後者更接近對自己貢獻過的東西最基本的處置權，兩者
  刻意不同高標準，不是本票的不一致，理由見 migration 對這支函式的裁量說明。
- **用途**：軟刪（`p_deleted = true`）／還原（`p_deleted = false`）。**owner 對別人
  相簿唯一能做的操作**——這支只碰 `deleted_at` 一欄，owner 分支不可能被拿來竄改
  `title`／`child_id`／`cover_media_id`（物理上不會執行到那些欄位的 `UPDATE`）。
  建立者對自己的相簿仍可直接 `.update()` 軟刪／還原（見 §3，那條路徑要求仍是
  owner/member），這支 RPC 對建立者是多一條路徑而非唯一路徑，但**兩條路徑的
  授權範圍不同**——被降級成 viewer 的建立者，直接 `.update()` 會被排除（0 列），
  但這支 RPC 仍會成功，這是刻意的設計，不是疏漏。
- **與直接 `.update()` 的差異**：owner 對別人相簿直接下 `.update({deleted_at: ...})`
  會被 policy 排除、靜默影響 0 列（見 §2「寫入路徑小結」的例外說明），**不會**
  拿到錯誤；這支 RPC 才是 owner 想確認成功／失敗的正確呼叫方式，失敗會拿到明確的
  錯誤碼。
- **錯誤碼**：未登入 `42501`；相簿不存在 `LS023`；不是建立者也不是該家 owner，或
  雖是建立者但已完全離開該家庭 `42501`。
- **併發**：對目標列用 `FOR UPDATE` 鎖住，**這把鎖不可移除**——授權判斷讀的
  `family_id`（`v_album.family_id`）就是從這本相簿這一列本身讀來的，不是不變的
  外部資料。`albums_update` policy 的建立者分支允許建立者把自己的相簿直接
  `.update()` 搬到自己也是 contributor 的另一個家庭（`family_id in
  contributor_family_ids()`，見 §3；這件事本身是否該被允許是另一個未決的產品
  問題，登記在 LS-57，不在本票範圍）——若這支 RPC 拿掉 `FOR UPDATE`，建立者的
  搬家與原家庭 owner 的軟刪同時發生時：原家庭 owner 呼叫這支 RPC 讀到的會是
  搬家**之前**的 `family_id`（授權判斷通過，因為讀到的還是自己家），但函式尾端
  的 `UPDATE`（`SECURITY DEFINER`，不受 RLS 保護）會在建立者的搬家 commit 之後
  才真正執行，寫入時這本相簿**已經**屬於別的家庭——原家庭 owner 因此對一本此刻
  已不屬於自己家庭的相簿完成了軟刪，是一次跨家庭越權。本機實測重現過這個結果
  （拿掉 `FOR UPDATE` 後、對調 fixture 的最小 repro：授權判斷回報「通過」、
  最終列確實被軟刪，即使它此刻的 `family_id` 已經是另一個家庭），
  `supabase/tests/concurrency/album_edit_vs_delete_s1_move_family.sql`／
  `s2_delete_after_move.sql` 這組 race case 就是把這個場景寫成回歸測試，拿掉
  `FOR UPDATE` 會讓它變紅（mutation 證據見 `s2_delete_after_move.sql` 檔頭）。
  既有的 `album_edit_vs_delete_s1_update.sql`／
  `s1_delete.sql` 兩組（作者改 `title`、owner 軟刪同時發生）測不到這件事——
  `title` 不是授權判斷讀的欄位，這兩組能證明的是「序列化正確、沒有互相覆蓋
  對方寫的欄位」，不是「`FOR UPDATE` 本身必要」，兩件事不能混為一談。

### `set_comment_deleted(p_comment_id uuid, p_deleted boolean) -> void`
- **誰能呼叫**：作者本人（**只要求仍是該家庭任一角色的成員**，包含被降級成 viewer
  的情況——跟 `update_comment` 的作者分支判準一致，見下）**或**該家庭的 owner
  （家庭內任何一則留言）。
- **用途**：軟刪（`p_deleted = true`）／還原（`p_deleted = false`）。**owner 對別人
  留言唯一能做的操作**——這支只碰 `deleted_at` 一欄，owner 分支不可能被拿來竄改
  `body`。作者對自己的留言也可以用這支 RPC 軟刪／還原，或改用 `update_comment` 間接
  觸發（見下）。
- **與 LS-58 之前的差異**：`comments` 收斂成 RPC-only 之前，owner 對別人留言直接下
  `.update({deleted_at: ...})` 會靜默影響 0 列；收斂之後**任何人**直接 `.update()`
  comments 都會拿到明確的 `42501`（見 §2「寫入路徑小結」），不再有「靜默 0 列」這種
  模稜兩可的結果——這支 RPC 現在不只是「owner 想確認成功／失敗的正確呼叫方式」，
  是唯一能碰 `deleted_at` 的路徑。
- **錯誤碼**：未登入 `42501`；留言不存在 `LS024`；不是作者也不是該家 owner，或
  雖是作者但已離開家庭 `42501`。
- **併發**：對目標列用 `FOR UPDATE` 鎖住。這把鎖原本是為了擋住「作者把留言直接
  `.update()` 搬到另一個家庭、同時 owner 對原家庭那一列軟刪」的跨家庭越權
  race——`comments` 收斂成 RPC-only 之後，`update_comment` 的參數只有 `body`，
  已經沒有任何路徑能搬動 `family_id`，這個特定 race 場景在前提上已經不成立
  （不是靠鎖擋住）。鎖本身仍然保留（migration 是歷史紀錄不回頭改），繼續為
  `update_comment` 與 `set_comment_deleted` 之間的一般序列化把關，回歸測試見
  `supabase/tests/concurrency/comment_edit_vs_delete_setup.sql` 一組（編輯／軟刪
  兩個方向）。

### `create_comment(p_family_id uuid, p_target_type text, p_target_id uuid, p_body text) -> uuid`
- **誰能呼叫**：**任何角色**（含 viewer），比照收斂前 `comments_insert` policy 的
  授權範圍——PLAN §3「Viewer 只能看與留言」是產品定案，不是 LS-58 的裁量。
- **回傳**：新留言的 `id`。
- **副作用**：`author_id` 恆為呼叫者本人，不接受由參數指定（防冒名，同
  `create_diary_entry`／`media.uploaded_by` 的既有慣例）。
- **參數**：`p_target_type` 傳字串（cast 失敗 `22P02`，值域見 §3「target_type ∈
  album|media|diary|comment」）；`p_target_id` 若查得到（不是孤兒 id）就必須屬於
  `p_family_id`，否則 `LS026`（見 §3、LS-58 R1）；查不到維持既有裁量放行。
  `p_body` 為空或超過 2000 字 `23514`（`CHECK` 約束，非本 RPC 自訂）。
- **錯誤碼**：未登入 `42501`；不是該家任一角色的成員 `42501`；`target_id` 存在但屬於
  別的家庭 `LS026`。
- **併發**：無特殊語意，單一 `INSERT`。

### `update_comment(p_comment_id uuid, p_body text) -> void`
- **誰能呼叫**：**只有原作者本人，且必須現在仍是該家庭任一角色的成員**——這裡刻意
  不要求 owner/member（跟 `update_diary_entry` 要求仍是 owner/member 不同），因為
  收斂前的 `comments_update` policy 作者分支從一開始就沒有排除 viewer，LS-58 收斂
  時原樣延續，不是新放寬也不是向 diaries 看齊。
- **語意**：只有 `body` 一個欄位可改，沒有 PUT／PATCH 的分歧問題。**刻意不檢查
  `deleted_at`**——已被軟刪除的留言仍可編輯（跟 `update_diary_entry` 不同，那支明確
  拒絕編輯已軟刪除的日記）：收斂前的 `comments_update` policy 從來沒有這條限制，
  `albums_update` 的作者分支現在也還是沒有，這不是通用規則，是 `diaries` 自己的
  產品決定，comments 沒有理由被動繼承。
- **錯誤碼**：未登入 `42501`；留言不存在 `LS024`；不是作者本人、或雖是作者但已不是
  該家庭任一角色的成員 `LS025`（兩種情況共用同一個碼，排在「留言不存在」的檢查之後
  ——同 `update_diary_entry`／`approve_join` 的既有慣例，未通過授權的人不會從錯誤碼
  差異推敲出更多資訊）。
- **併發**：對目標列用 `FOR UPDATE` 鎖住，與 `set_comment_deleted` 互相排隊（見上）。

### `toggle_reaction(p_family_id uuid, p_target_type text, p_target_id uuid) -> boolean`
- **誰能呼叫**：**任何角色**（含 viewer），比照收斂前 `reactions_insert` policy 的
  授權範圍。
- **回傳**：`true`＝這次呼叫加入了反應；`false`＝這次呼叫收回了反應。同一人對同一
  `(target_type, target_id)` 只能有一顆愛心，這支 RPC 就是「切換」那顆愛心的唯一
  入口——呼叫端**不需要**自己先查有沒有按過，直接呼叫即可，回傳值就是切換後的狀態。
- **為什麼不能用直接 INSERT／DELETE**：`reactions_target_user_key`
  （`UNIQUE(target_type, target_id, user_id)`）在沒有序列化的情況下，兩個幾乎同時
  發出的呼叫都會查到「還沒按過」而各自嘗試 INSERT，第二個會撞 `23505`——這支 RPC
  用 `pg_advisory_xact_lock`（鎖鍵為 `(target_type, target_id, user_id)` 的雜湊）
  序列化查詢與加/刪，讓兩次幾乎同時的呼叫都能正常完成，不會有任何一次噴錯。
- **錯誤碼**：未登入 `42501`；不是該家任一角色的成員 `42501`；`target_id` 存在但
  屬於別的家庭 `LS026`（同 `create_comment`，LS-58 R1，見 §3）。
- **併發**：見上——這是這支 RPC 存在的核心理由，回歸測試見
  `supabase/tests/concurrency/reaction_toggle_race_*.sql`（同一人對同一目標的雙
  `toggle_reaction` 併發呼叫）。
- **`LS026` 在加入與收回兩條路徑之前都會擋**：檢查排在 `pg_advisory_xact_lock`
  與 `DELETE`／`INSERT` 之前，對**真的存在**的 target，用跟先前不同的
  `p_family_id` 想收回別家的反應會直接拿到 `LS026`，`DELETE` 完全不會執行。殘餘
  情況只剩 `target_id` 完全查不到（孤兒）時——細節見 §3「reactions」段。

### `list_comments(p_family_id uuid, p_target_type text, p_target_id uuid, p_cursor_created_at timestamptz default null, p_cursor_id uuid default null, p_limit integer default 20) -> table(id uuid, author_id uuid, author_display_name text, author_avatar_url text, body text, created_at timestamptz)`
- **誰能呼叫**：該家庭任一角色的成員；非本家庭成員呼叫會拿到明確的 `42501`
  （`security definer`，函式內部手動檢查成員資格——見下方「為什麼不是 invoker」）。
- **用途**：單一 target 的留言分頁（keyset），含軟刪過濾（`deleted_at is null`）與
  作者顯示名／頭像（join `profiles`，避免呼叫端逐則留言各查一次作者資料的 N+1）。
- **為什麼是 `security definer`，不是像 `get_family_timeline` 那樣選 invoker**：
  本機用 5 萬則留言（單一 target）實測，`security invoker`（仰賴 `comments_select`／
  `profiles_select` 既有 RLS）版本即使 `comments_target_idx` 完整存在，
  `authenticated` 身分下的查詢一律被規劃器改選 Bitmap／Seq Scan＋顯式 Sort
  （829-873 buffers），不是能讓 `LIMIT` 提早結束的 Index Scan Backward——RLS 的
  `family_id in (select private.family_ids())` 這個 hashed SubPlan 條件疊上去後，
  規劃器對它的選擇度估計不準，連帶誤判排序後索引掃描的成本高於整段掃描＋排序。改用
  definer、函式內部手動查一句 `exists (...)` 確認成員資格，繞過那個 hashed
  SubPlan，規劃器就正確選回 Index Scan Backward（buffers 降到個位數）。**副作用**
  （刻意接受）：作者若已離開這個家庭，他過去留言的顯示名稱依然看得到（不像
  `profiles_select` 的 `peer_profile_ids()` 只認「目前」同家庭的人）——這其實是更
  合理的行為，不是資訊洩漏（`display_name` 在這個 app 的信任模型裡只是暱稱）。完整
  的實測數據與取捨見 migration 對這支函式的說明。
- **分頁**：keyset，游標是 `(created_at, id)` 這一對，跟 `get_family_timeline` 同一套
  規則——第一頁兩個游標參數都不傳；**只傳其中一個會拿到 `LS022`**（跟
  `get_family_timeline` 共用同一個碼，語意完全相同：半游標不合法）。
- **`p_limit`**：下界夾到 1、上界夾到 100，預設 20，同 `get_family_timeline`。
- **錯誤碼**：未登入 `42501`；不是該家任一角色的成員 `42501`；半游標 `LS022`。
- **效能**：`language plpgsql`，依游標是否為 `NULL` 拆成兩條**靜態**查詢（同
  `get_family_timeline` 的 LS-48 F1 教訓），且刻意先在子查詢裡完成「篩選＋排序＋
  LIMIT」才 LEFT JOIN `profiles`，避免 `profiles` 的 join 被規劃器選成 Hash Join
  而把已經走對索引的 `comments` 那側整批物化。效能回歸見
  `supabase/tests/50_rls_plan_no_percall_subquery.sql` 的專屬段落。

### `get_reaction_counts(p_family_id uuid, p_target_type text, p_target_ids uuid[]) -> table(target_id uuid, reaction_count bigint, reacted_by_me boolean)`
- **誰能呼叫**：該家庭任一角色的成員；`security invoker`（依賴既有的
  `reactions_select` RLS，跟 `list_comments` 不同裁量——這支是單一靜態聚合查詢，
  沒有「排序＋LIMIT 提早結束」這個會被 RLS 選擇度誤判打斷的路徑，本機同樣灌測過
  沒有出現 `list_comments` 那種 Bitmap／Seq Scan 退化，見 migration 說明）。
- **用途**：批次彙總一頁內容（例如一頁留言、一頁相簿卡片）各自的愛心數與「我是否按過」，
  呼叫端傳一組 `target_id` 一次拿回全部計數，避免對每個 target 各查一次 `COUNT` 的
  N+1。
- **回傳規則**：**沒有任何反應的 `target_id` 不會出現在回傳列裡**（`GROUP BY` 天生
  排除 0 筆的組合）——呼叫端要把缺席的 `target_id` 當成 `reaction_count = 0`，同
  `get_my_join_request()`「0 列＝空結果」的既有慣例，不是遺漏。
- **非本家庭成員不會拿到錯誤**：這支是 `security invoker`，`p_family_id` 傳一個自己
  不屬於的家庭不會 raise，只會依 `reactions_select` RLS 自然回傳空集合——跟
  `get_family_timeline` 是同一種行為（見該支說明），**跟 `create_comment`／
  `toggle_reaction`／`list_comments` 呼叫端會拿到明確 `42501`／`LS026` 不同**，呼叫端
  不要假設這支「傳錯家庭一定會報錯」。
- **`p_target_ids` 沒有長度上限**：不像 `list_comments` 的 `p_limit` 有
  `least(greatest(…,1),100)` 夾定，這支目前刻意不設硬上限（`security invoker` 加上
  `reactions_select` 既有 RLS 已經是隔離防線，過大的陣列只會拉長查詢時間，不是安全
  問題）——呼叫端仍建議依實際使用情境（例如一頁留言、一頁相簿卡片）控制批次大小，
  不要一次傳整個家庭的所有 target_id。
- **錯誤碼**：`p_target_type` cast 失敗 `22P02`；未登入時 `auth.uid()` 為 `NULL`，
  配合 RLS 自然回傳空集合（同 `get_family_timeline` 的未登入行為），不 raise。
- **併發**：無寫入，讀取穩定（`stable`），不會有寫入衝突。

### `get_family_timeline(p_family_id uuid, p_child_id uuid default null, p_cursor_occurred_at timestamptz default null, p_cursor_ref_id uuid default null, p_limit integer default 20) -> table(kind public.feed_kind, ref_id uuid, occurred_at timestamptz, child_id uuid)`
- **誰能呼叫**：任何已登入使用者，但只查得到自己所屬家庭的資料——`p_family_id` 傳一個
  自己不屬於的家庭不會報錯，只會回傳 0 列（`security invoker`，完全依賴 `feed_items`
  既有的 `feed_items_select` RLS policy，見 §3）。
- **回傳的 `kind`**：`public.feed_kind` 這個 enum（`album`/`media`/`diary`），不是泛用
  `text`——PostgREST 會把 enum 序列化成 JSON 字串，Swift 端可以直接對映成一個三選一的
  型別（例如 `enum FeedKind: String, Decodable { case album, media, diary }`），不需要
  自己防禦「萬一多一種字串」這種情況。
- **用途**：時間軸混排查詢（日記＋相簿＋照片），取代直接 `.from("feed_items")` 拼
  keyset 條件。回傳的是**指標**（`kind`／`ref_id`），不是完整內容——要看某一頁的完整
  資料（日記內文、相簿標題、照片路徑），**依 `kind` 分組後各發一支批次查詢**，不要對
  每一列各發一次請求。三支查詢彼此獨立（不同表、不同 RLS 判斷），**用
  `withThrowingTaskGroup` 平行發出，不要序列 `await`**——序列寫法雖然一樣只有 3 次
  網路請求（不是 N+1），但頁面延遲會變成三支查詢時間相加，而不是三者當中最慢的那支：
  ```swift
  // 一頁最多 3 支 kind（album/media/diary），所以每頁封頂 3 次查詢，不是每列一次；
  // 三支彼此獨立，平行發出而不是序列 await，頁面延遲取決於最慢的那支，不是總和。
  let byKind = Dictionary(grouping: page, by: \.kind)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for (kind, items) in byKind {
      group.addTask {
        let ids = items.map(\.refId)
        // 例如 diary：await supabase.from("diaries").select().in("id", value: ids)
        // 各支查詢各自寫回對應的本地快取／狀態，不需要彼此的回傳值
      }
    }
    try await group.waitForAll()
  }
  ```
  這是「依 kind 分組、`in.(ref_id,…)` 每頁最多 3 次查詢、且三次平行發出」，不是逐列
  各查一次的 N+1，也不是看似批次、實則序列等待三倍延遲的假平行；皆已有 RLS 保護，
  family 成員本來就查得到，不需要額外授權。
- **`p_child_id`**：`NULL`＝不篩（回傳全部，含 `child_id` 為 NULL 的項目與所有
  `media`）；帶值＝只回傳 `child_id` 等於該值的項目。**`media` 類項目在指定 `p_child_id`
  時恆不出現**（見 §3 `feed_items` 段的裁量說明），這不是 bug。
- **分頁**：keyset，游標是 `(p_cursor_occurred_at, p_cursor_ref_id)` 這一對——傳上一頁
  最後一列的 `occurred_at`／`ref_id`。第一頁兩者都不傳（或都傳 `NULL`）。**只傳其中
  一個（另一個留 `NULL`）會拿到 `LS022`**——半游標不是合法用法，呼叫端要嘛都傳、要嘛
  都不傳；這支 RPC 不會為了容錯半游標而靜默回傳空集合（那會讓呼叫端誤判成「這頁真的
  沒資料了」）。
- **`p_limit`**：下界會被夾到 1（傳 `0` 或負數不會被誤用成「不限筆數」）、上界夾到
  100；預設 20。兩端都有測試覆蓋（`supabase/tests/85_diaries_timeline.sql`，上界測試
  用了一個 >100 筆的家庭資料集，不是只驗小數字下「反正沒差」的空案例）。
- **錯誤碼**：未登入時 `auth.uid()` 為 `NULL`，配合 RLS 自然回傳 0 列，不 raise；
  游標只傳一半 `LS022`。
- **併發**：無寫入，讀取穩定（`stable`），不會有寫入衝突。
- **效能**：`language plpgsql`，依 `p_child_id`／游標是否為 `NULL` 拆成四條各自可以
  走索引的靜態查詢（不是同一句 SQL 裡的 `OR` 分支）——這是刻意的實作選擇，不只是
  風格：`language sql` 搭配 `set search_path` 會讓函式無法被規劃器 inline，`OR` 條件
  就下推不進 index cond。細節與 EXPLAIN 證據見 migration 內
  `public.get_family_timeline` 的完整說明與
  `supabase/tests/50_rls_plan_no_percall_subquery.sql` 的專屬效能回歸段落。

---

## 5. 錯誤碼全表

自訂 `SQLSTATE` 一律是 `LS0xx`/`LS1xx` 格式（5 碼英數，符合 Postgres 自訂 errcode 慣例）。
Swift 端 `LSErrorCode`（`LittleSprout/Errors/AppError.swift`）逐碼列舉本表全部自訂碼，不用字串
前綴比對；本表與 `LSErrorCode` 的雙向集合一致由 `scripts/gates/error-codes-check.sh` 機械對帳
（push-gate＋CI rules job，LS-54），見本節末。

| 碼 | 意義 | 由哪支 RPC／哪個路徑觸發 |
|---|---|---|
| `LS001` | 家庭必須至少保留一位 owner | `family_members` 的 DELETE／UPDATE（trigger `private.enforce_family_has_owner`）——不限於 RPC，直接對 `family_members` 做會導致 0 owner 的 UPDATE/DELETE 也會觸發 |
| `LS002` | 家庭已達儲存額度上限，無法再上傳 | `media` 的 INSERT／UPDATE（trigger `private.media_storage_sync`） |
| `LS010` | 邀請碼不存在 | `request_join` |
| `LS011` | 邀請碼已過期 | `request_join` |
| `LS012` | 邀請碼的使用次數已用完 | `request_join` |
| `LS013` | 你已經是這個家庭的成員 | `request_join` |
| `LS014` | 你對這個家庭已經有一筆待審核的申請 | `request_join` |
| `LS015` | 申請不存在或已被處理 | `approve_join`／`reject_join`／`withdraw_join` |
| `LS016` | 邀請碼產生連續撞碼，請重試 | `create_invite`（機率極低，代表亂數來源異常，不是使用者可修正的錯誤，UI 顯示通用重試訊息即可；Swift 端 `AppError`／`LSErrorCode.Tier` 把它歸在 `retryableSystem` 層——跟 LS010/LS011/LS012 那種「換個輸入」的 `validationRetryable` 不同，見 LS-55 N9） |
| `LS017` | 邀請碼參數不合法（到期時間或可用次數超出範圍） | `create_invite` |
| `LS020` | 日記不存在，或（`update_diary_entry` 情境）已被軟刪除須先還原 | `update_diary_entry`／`set_diary_deleted` |
| `LS021` | 不是作者本人，或雖是作者但已不是該家庭 owner/member | `update_diary_entry` |
| `LS022` | keyset 分頁的游標參數只給了一半（兩個游標參數要嘛都給、要嘛都不給） | `get_family_timeline`／`list_comments`（游標都是呼叫端自己組的，不是使用者輸入——使用者沒有東西可換，原地重試不會成功；Swift 端 `AppError`／`LSErrorCode.Tier` 把它歸在 `rejected` 層，不是 `validationRetryable`，見 LS-55 PR #77 R1 裁決） |
| `LS023` | 相簿不存在 | `set_album_deleted` |
| `LS024` | 留言不存在 | `update_comment`／`set_comment_deleted` |
| `LS025` | 不是留言作者本人，或雖是作者但已離開該家庭 | `update_comment` |
| `LS026` | 留言／按讚的 target 存在，但屬於別的家庭 | `create_comment`／`toggle_reaction` |
| `42501` | 未登入，或權限不足（不是該家 owner／不是申請人本人／不是作者本人／作者已離開家庭／不是該家任一角色成員／直接寫入被 grant 擋下） | 所有 RPC 皆可能；也是**任何直接對 RPC-only 表寫入**（如 `family_members` INSERT、`invites` INSERT/UPDATE、`join_requests` 任何寫入、`diaries` INSERT/UPDATE、`comments` INSERT/UPDATE、`reactions` INSERT/DELETE）會拿到的標準碼——PostgREST 對 grant 被收回的操作回這個碼，訊息只會是通用的 permission denied，不會有自訂文字。**例外**：owner 對別人的 `albums` 直接 `.update()` 內容欄位**不會**拿到這個碼，是靜默影響 0 列，見 §2「寫入路徑小結」的例外說明（`comments` 自 LS-58 起不再適用這條例外，直接 `.update()` 一律 `42501`） |

**沒有被上面任何一支 RPC 包住、可能直接從 PostgREST 冒出來的標準 Postgres 錯誤碼**
（直接 `.insert()`/`.update()` 到允許直寫的表時可能撞到，client 應該當成一般失敗處理，
不必逐碼分文案，除非產品需求特別要求）：

| 碼 | 常見觸發情境 |
|---|---|
| `23502`（`not_null_violation`） | 必填欄位留空，例如 `children.birthday`、`media.byte_size` |
| `23514`（`check_violation`） | 違反欄位 `CHECK`，例如 `families.name` 長度、`media.width/height > 0`、`diaries.body` 長度 |
| `22P02`（`invalid_text_representation`） | enum 欄位傳了不合法的字串（例如 `role` 不是 `owner/member/viewer`） |
| `23505`（`unique_violation`） | 例如 `blocked_users` 重複封鎖同一人（`reactions` 自 LS-58 起不會了——直接 INSERT 已被 revoke，`toggle_reaction` 用 advisory lock 序列化，不會撞這個碼） |
| `23503`（`foreign_key_violation`） | 例如 `albums.child_id` 指到別家的孩子（複合外鍵擋下） |

**Swift 端覆蓋現況（LS-54 D4 改寫；原「repo 尚未有網路層 Swift 程式碼、留給 LS-17」的段落已被
LS-49 推翻）**：`LSErrorCode` 已逐碼涵蓋上表全部自訂碼——`LS001`／`LS002` 與 `LS010`–`LS017`
（LS-49）、`LS020`–`LS022`（LS-54 補齊，歸層：`LS020`／`LS021`／`LS022` → `rejected`；`LS022`
原本歸 `validationRetryable`，PR #77 R1 review 指出游標是呼叫端自己組的、使用者無輸入可換，
改歸 `rejected`，見上方 `LS022` 列註記）、`LS023`／`LS024`（LS-52 補齊，歸層皆 `rejected`）、
`LS025`（LS-58 補齊，歸層 `rejected`——跟 `LS021`／`LS023`／`LS024` 同一類：不是作者本人、或
雖是作者但已離開家庭，換輸入沒有用，UI 該做的是隱藏編輯入口而不是讓使用者重試）、`LS026`
（LS-58 R1 補齊，歸層 `rejected`——target 存在但屬於別的家庭，這是呼叫端組錯參數／資料
被竄改的訊號，不是「換個輸入再試」能解的，UI 該做的是回上一頁或重新整理而不是原地重試）；
`LS016` 另於 LS-55 從 `validationRetryable` 改歸新增的 `retryableSystem` 層（見上方 `LS016`
列註記）。三層（`validationRetryable`／`retryableSystem`／`rejected`）歸類由
`LittleSproutTests/AppErrorTests.swift` 的列舉測試逐碼釘住。
**尚缺碼：無**。之後每新增一個自訂碼，本表與 `LSErrorCode` 必須同 PR 更新，否則
`error-codes-check` 會紅（任一邊多都算；gate 只認本節表格列的 `` `LSnnn` `` 首欄，散文提及不計）。

---

## 6. Storage：media bucket 與路徑規約

實作於 `supabase/migrations/20260823030000_storage_policies.sql`（LS-40）。

### Bucket
- 名稱：`media`，**private**（`public = false`）——PLAN §8「全私有 bucket + 簽名 URL」，
  照片影片不會有公開網址；client 讀取一律用簽名 URL（`createSignedURL`），不要嘗試組
  公開網址。
- `file_size_limit`：50 MiB（52428800 bytes），與 `supabase/config.toml` 的
  `[storage] file_size_limit` 對齊。
- `allowed_mime_types`：`image/jpeg`、`image/png`、`image/heic`、`image/heif`、
  `video/mp4`、`video/quicktime`（`.mov`）。其他型別在 Storage 層就會被拒絕，不會走到
  `media` 表。

### 路徑規約
```
{family_id}/{yyyy}/{mm}/{media_id}.{ext}          -- 原始檔案
{family_id}/{yyyy}/{mm}/{media_id}_thumb.jpg       -- 縮圖
```
- `{yyyy}/{mm}` 取**上傳時間**，不取 `taken_at`（PLAN §5：這個前綴的用途是搬移分片，
  用拍攝時間會讓回填舊照片時分片散開）。這條規則是**客戶端契約**，DB 的 policy
  管不到（DB 無從得知「這是不是真的上傳當下的月份」）。
- `{family_id}`／`{media_id}` **必須是小寫正規形 UUID**（`8-4-4-4-12` 格式，全小寫）。
  這不是潔癖：`public.media.storage_path` 的 `CHECK` 約束比對的是
  `family_id::text`，Postgres 的 uuid 輸出恆為小寫正規形；兩邊大小寫不一致，同一張
  照片在 `media` 表與 Storage 會長成兩種路徑，對不起來。
  **Swift 的 `UUID().uuidString` 預設是大寫，上傳路徑必須呼叫 `.lowercased()`**——
  這是本節唯一一條「違反了會直接被 policy 擋下（`42501`／INSERT 失敗）」的客戶端
  硬性要求。
- 副檔名只接受：`jpg`／`jpeg`／`png`／`heic`／`heif`／`mp4`／`mov`，或縮圖固定
  `_thumb.jpg`。

### storage.objects 的 RLS（四條 policy，皆 `to authenticated`）

| 操作 | 誰可以 | 額外限制 |
|---|---|---|
| SELECT | 同家庭任何角色（含 viewer） | 只看得到路徑第一段＝自己所屬家庭的物件；不檢查路徑規約，讀取端不因格式問題被擋 |
| INSERT | 有上傳權者（owner 恆可；member 看 `can_upload`；viewer 不行） | 路徑必須符合規約且第一段＝自己**當下**所屬的家庭（防跨家庭寫入）；`owner`/`owner_id` 欄位（storage-api 自動填）必須是自己或留空 |
| UPDATE | 家庭 owner（任意物件）；或上傳者本人（僅限**當下**仍有上傳權時） | 新路徑同樣要通過規約與家庭歸屬檢查（防止「改名搬家」繞過 INSERT 邊界） |
| DELETE | 同 UPDATE 的判準 | 上傳者可以刪自己上傳的孤兒物件（見 §3 `media` 的「上傳流程順序」）；已軟刪除的 `media` 對應物件**不要**跟著硬刪 Storage 檔案（PLAN §5：軟刪除要留救援路徑） |

- **`can_upload` 被收回後的行為是「當下判斷」不是「上傳當時判斷」**：owner 把某成員的
  `can_upload` 關掉之後，那個人連自己以前上傳的檔案都改／刪不了——這是刻意選的較嚴
  一邊，代價是「被撤權成員留下的孤兒物件改由家庭 owner 清理」，寫進這裡供 UI 文案
  參考（例如撤銷上傳權的確認對話框可以提一句）。
- **簽名 URL 與 egress 防線**（PLAN §7／§8：長輩會反覆滑同一批照片，這項比想像中容易
  吃流量）：列表畫面只載縮圖（`_thumb.jpg`）簽名 URL，點開大圖才拿原檔簽名 URL——
  這是 client 實作責任，不是 DB 能強制的事，這裡只記策略。

---

## 7. 邀請／加入／核准狀態機

實作於 `supabase/migrations/20260823010000_join_approval.sql`（LS-33）與
`20260823040000_invites_write_path.sql`（LS-37）。

```
owner: create_invite(family_id, role, expires_at, max_uses) -> code
                          │
申請人: request_join(code)
                          │
              驗證：碼存在？未過期？次數未用完？不是已成員？沒有其他 pending 申請？
                          │
              ┌───────────┴───────────┐
    families.require_approval=true    families.require_approval=false
              │                                   │
    建 join_requests(pending)              直接 insert family_members
    used_count +1                          used_count +1
    回傳 status="pending"                   回傳 status="joined"
              │
    owner: approve_join(request_id)  或  reject_join(request_id)
              │                              │
    insert family_members                  status="rejected"
    status="approved"                      （不寫 family_members）
              │
    （申請人也可在 pending 期間自行 withdraw_join(request_id) → status="withdrawn"）
```

**設計上的硬決定（client 要知道、不要假設反直覺的行為）**：

1. **`used_count` 在「申請成立」時就消耗，不是核准時**——即使家庭開了審核、申請人還在
   排隊等待，那個名額已經算用掉了。拒絕／撤回**都不退還**次數。UI 若要顯示「剩餘
   名額」，語意是「還能送出幾次申請」，不是「還能核准幾個人」。
2. **拒絕與撤回是兩種不同狀態**（`rejected` vs `withdrawn`），不要合併成同一個文案——
   對申請人是完全不同的敘述（「對方拒絕了你」vs「你自己撤回了」）。
3. **邀請碼沒有軟撤銷**：owner 想讓一支碼失效，唯一路徑是 `DELETE` 該列（會連帶
   cascade 掉底下所有 pending 申請，那些申請人的 `get_my_join_request()` 之後會查
   不到那筆申請——UI 要能處理「原本在等待，突然查不到了」這種情況，不是錯誤）。
4. **`request_join` 的碼比對已內建正規化**（去除非英數、轉大寫），輸入框不需要自己
   先清理格式，但也不會因為多打了空格或連字號而報「格式錯誤」——直接把使用者輸入
   原封不動傳給 RPC 即可。
5. **併發已經在 DB 層處理好**（見 §4 `request_join`/`approve_join`/`reject_join` 的
   併發段落）：兩人同搶最後一個名額、或核准與拒絕同時發生，DB 會序列化並給出確定
   的錯誤碼，client 不需要自己做樂觀鎖或重試邏輯。

---

## 8. 多寶貝約束（children 一對多）

- `children.family_id` → `families.id`：**一個 family 可以有多個 children**（1:N），
  PLAN §1「同時看自己家和妹妹家的小孩」是跨 family 的情境，這裡講的是同一個 family
  內可以登記多個孩子（例如雙胞胎、或大寶二寶）。
- `albums.child_id` / `diaries.child_id`：**可為 NULL**（不特別掛在某個孩子底下的
  家庭共用內容），非 NULL 時透過複合外鍵 `(family_id, child_id) → children(family_id, id)`
  綁定，確保不會掛到別家的孩子。**一個相簿／日記最多對應一個孩子**（N:1，不是多對多）
  ——沒有「一本日記同時記錄兩個孩子」的資料結構；若產品需求真的要跨孩子的內容，目前
  的設計是建立時不填 `child_id`（家庭共用），不是掛多個孩子。
- 沒有任何約束限制「同一個孩子只能有一個相簿／一篇日記」——`albums`/`diaries` 對
  `child_id` 沒有 UNIQUE，一個孩子可以有任意多本相簿與日記（1:N，這才是常態）。
- `media` 本身**不**直接關聯 `child_id`——照片只透過 `album_media`/`diary_media` 間接
  掛在有 `child_id` 的相簿／日記底下。要查「某個孩子的所有照片」，正確路徑是先查
  `albums`/`diaries` where `child_id = ?`，再 join `album_media`/`diary_media` 取
  `media`，**不是**在 `media` 表上直接篩選（那個欄位不存在）。
- **時間軸的單寶貝篩選**（LS-48，`get_family_timeline` 的 `p_child_id` 參數，見 §4）：
  這是「全部／單寶貝」兩種篩選，是 LS-47（多寶貝 UI 定案）之前的暫定硬需求，不是最終
  設計。指定 `p_child_id` 時，時間軸只回傳 `diary`／`album` 類項目（各自的 `child_id`
  等於該值），**`media` 類項目一律不出現**——因為 `media` 沒有直接的 `child_id`
  可比對，見上一條。這與「查某個孩子的所有照片」是兩件不同的事：後者要走上一條的
  join 路徑，`get_family_timeline` 的單寶貝篩選目前只涵蓋日記與相簿本身。

---

## 9. 機械對帳清單（gate 讀取，勿手動改格式）

以下兩個區塊由 `scripts/gates/api-contract-check.sh` 解析：每行一個項目，`<!-- API-CONTRACT:RPC`
與 `<!-- API-CONTRACT:TABLES` 開頭、`-->` 結尾之間的內容必須恰好等於從
`supabase/migrations/*.sql` 抽出的 `public` schema RPC 簽章與表名清單（順序不拘，多一項
少一項都會讓 gate 變紅）。**改 schema 時，先跑一次 `bash scripts/gates/api-contract-check.sh`
確認紅燈的差異訊息，再回來同步這兩個區塊**——不要手動猜測格式。

**權威性（LS-54 N4）**：CI `db` job 以 `--catalog`（`supabase db reset` 後查活資料庫 `pg_catalog`）
為權威來源；本機 push-gate 的文字解析模式是 best-effort（已知限制見
`scripts/gates/api_contract_check.py` 檔頭）。兩者不一致時一律以 CI 為準——本機綠、CI 紅就是
schema 或本文要修，不是 gate 要調。

<!-- API-CONTRACT:RPC
approve_join(uuid)
create_comment(uuid, text, uuid, text)
create_diary_entry(uuid, uuid, text, date)
create_invite(uuid, text, timestamptz, integer)
get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
get_my_join_request()
get_reaction_counts(uuid, text, uuid[])
list_comments(uuid, text, uuid, timestamptz, uuid, integer)
list_join_requests()
register_device_token(text, text)
reject_join(uuid)
request_join(text)
set_album_deleted(uuid, boolean)
set_comment_deleted(uuid, boolean)
set_diary_deleted(uuid, boolean)
toggle_reaction(uuid, text, uuid)
update_comment(uuid, text)
update_diary_entry(uuid, text, date, uuid)
withdraw_join(uuid)
-->

<!-- API-CONTRACT:TABLES
album_media
albums
blocked_users
children
comments
content_reports
device_tokens
diaries
diary_media
families
family_members
feed_items
invites
join_requests
media
notification_events
profiles
reactions
-->
