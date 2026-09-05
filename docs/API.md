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
> LS-33／LS-36／LS-37／LS-40／LS-48／LS-52／LS-58／LS-66／LS-121）。

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
10. [Edge Functions](#10-edge-functions)
11. [營運操作手冊](#11-營運操作手冊)

---

## 1. 連線基礎

- 後端＝Supabase：Postgres（PostgREST 自動生成 REST）＋ Auth ＋ Storage。iOS 端用
  `supabase-swift`，不要手刻 HTTP 呼叫。
- 所有資料表與 RPC 都在 `public` schema（`supabase/config.toml` 的 `api.schemas` 只暴露
  `public`／`graphql_public`）；`private` schema 的函式**不對外**，client 永遠呼叫不到，
  不需要也不應該嘗試。
- 認證：Supabase Auth（Sign in with Apple／Email OTP，LS-17；Google OAuth，LS-39——走
  `signInWithOAuth`＋`ASWebAuthenticationSession`／SwiftUI `WebAuthenticationSession`，
  redirect URL `littlesprout://auth/callback`，不裝 Google Sign-In SDK）。所有表與 RPC 的權限判斷
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
| `profiles` | 同家庭成員互看 | 由 `auth.users` insert trigger 自動建立；INSERT grant／`profiles_insert` policy 仍在（未被 revoke，LS-107 `ensureProfileExists` 的冪等 upsert 靠它），client 慣例上不直接 insert，若呼叫則是 upsert 冪等（`ON CONFLICT DO NOTHING`） | 僅自己 | ❌ 無 delete policy | 帳號刪除走 Auth 側 cascade。`eula_accepted_version`／`eula_accepted_at`（LS-197）：**client 讀得到、改不動**——只能透過 `accept_eula()` 寫入，見 §4／§11 |
| `families` | 我所屬的家庭 | 任何登入者（自建家庭），但 (a) 呼叫者已被停權，或 (b) `app_settings.registrations_open = false` 時一律拒絕（`LS052`／`LS054`，LS-179，見 §11） | `name`／`require_approval` 兩欄，owner-only | ❌ 無 delete policy | `storage_quota_bytes`／`storage_used_bytes` 兩個額度欄位永遠唯讀——不論身分，client 都改不動（只有 `media` 表的 trigger 與表擁有者能寫）。`suspended_at`（LS-179）：**client 讀得到**（停權事實本來就會從 `LS052`／`LS053` 揭露），但改不動，只有表擁有者（postgres，Dashboard／`db query --linked`）能寫；停權原因不在這張表上，見 §11 與 `private.suspension_notes` |
| `app_settings`（LS-179／LS-197） | `registrations_open`／`updated_at`／`id` 🔒 完全不可讀（`authenticated` 無 grant、無 policy）；`eula_version`（LS-197）**client 讀得到**（欄位級 `SELECT`＋`app_settings_select` policy，見 §11） | 🔒 唯讀（只有表擁有者能寫，見 §11） | 🔒 唯讀 | 🔒 唯讀 | 全域營運開關（`registrations_open`／`eula_version`）。`registrations_open` 只透過 `private.registrations_open()`（`SECURITY DEFINER`）供其他函式內部讀，client 不會直接碰到；`eula_version` 則刻意開放 client 直接讀（呼叫 `accept_eula()` 前需要知道目前版本），見 §11 |
| `family_members` | 我所屬家庭的成員 | 🔒 **RPC-only**（`request_join`／`approve_join`，直接 INSERT 已被 revoke） | 僅 `role`／`can_upload` 兩欄，owner-only | owner 移除任何人；任何人可自行退出 | LS-33/LS-6 收斂：不存在「owner 直接把任意 user_id 塞進成員名單」的路徑 |
| `invites` | owner 看自家的邀請碼 | 🔒 **RPC-only**（`create_invite`，直接 INSERT 已被 revoke） | 🔒 **無 UPDATE 路徑**（policy 與 grant 兩層都關，LS-37） | owner 撤銷（DELETE，cascade 掉底下的 pending 申請） | 撤銷邀請碼＝DELETE 該列，沒有「軟撤銷」欄位 |
| `children` | 我所屬家庭的孩子；**不分角色、不分軟刪與否**——owner／member／viewer 都讀得到全部列，含已軟刪的（`deleted_at`／`deleted_by` 對所有人都是可見的唯讀旗標，R1 I3/I4） | 🔒 **RPC-only**（`create_child`，owner／member 皆可，直接 INSERT 已被 revoke） | 🔒 **RPC-only**：內容（`name`／`birthday`／`avatar_url`）owner／member 皆可用 `update_child`；軟刪／還原（`deleted_at`／`deleted_by`）僅 owner 用 `set_child_deleted`（直接 UPDATE 已被 revoke） | 🔒 **無 DELETE 路徑**（R1 I5：直接硬刪會繞過 30 天保護，policy 與 grant 兩層都關，連 owner 也沒有） | LS-66 收斂：`family_id` 建立後不可變（trigger 額外把關）；軟刪 30 天內可還原（重複軟刪 no-op，不刷新時鐘，見 §4），超過拿 `LS043`；已軟刪的孩子不能再被指定為新內容的標記（`LS044`，LS-121 起守門搬到 `diary_children`／`album_children` 連結表的 `BEFORE INSERT` trigger）；既有標記不隨軟刪連動，見 §8 |
| `media` | 我所屬家庭**尚未軟刪**的檔案中繼資料，**上傳者自己的例外**——不論是否已軟刪都看得到自己上傳的列（`deleted_at is null or uploaded_by = auth.uid()`，LS-155 R2 起；與 `children` 全員可見已軟刪列的例外不同，這裡只有上傳者本人是例外，見 §3「`media_select` 過濾」段落的已知殘留缺口） | 有上傳權者（`uploaded_by` 必須是自己） | 僅 `taken_at`／`deleted_at`／`width`／`height` 四欄；owner 任意列，上傳者僅自己上傳的**且當下仍有上傳權** | **文件承諾「owner 任意列」，實際只對 owner 自己上傳的列與尚未軟刪的別人的列成立**（一般刪除走 `deleted_at`）——owner 對「別人上傳、已軟刪」的列直接 `DELETE` 會因為 R2 的 `media_select` 把該列藏起來而**靜默影響 0 列**（LS-155 R2 review m1 實測，見 §3 殘留缺口段落）；真正的 owner moderation 請走 `remove_content_as_owner('media', id)`（`SECURITY DEFINER`，不受這個限制） | `byte_size`／`storage_path`／`family_id`／`uploaded_by`／`thumb_path`／`thumb_width`／`thumb_height`（LS-128）／`duration_seconds`（LS-134）一旦寫入不可改；`can_upload` 被 owner 關掉後，非 owner 的原上傳者連軟刪除自己的照片都會被拒（`42501`），見 §3 |
| `albums` | 我所屬家庭的相簿 | owner／member（`created_by` 必須是自己） | 🔀 **混合模式（LS-52；LS-57 R2 起範圍限縮；LS-121 起 `child_id` 移出本表）**：內容（title／cover_media_id）僅建立者本人直接 `.update()`；`deleted_at`／`deleted_by`／`family_id` 三欄自 LS-57 R2 起對 `authenticated` 已無 UPDATE 欄位級 grant，唯一路徑是 `set_album_deleted` RPC；寶貝標記唯一路徑是 `set_album_children` RPC（見 §4） | owner-only | Viewer 不可建立相簿；owner 對別人相簿的內容**沒有**直接 `.update()` 路徑——見 §3「為什麼 albums／comments／diaries 曾經、現在用了不同的寫入模型」；`album_children`（見下）任何一列的 `child_id` 指向一個已軟刪的孩子時 INSERT 皆拿 `LS044`，見 §8 |
| `album_media` | 同上 | owner／member | owner／member | owner／member | 連結表自帶 `family_id`，policy 不必 join 回 `albums` |
| `album_summaries`（LS-200，view） | 我所屬家庭的相簿，逐列多帶 `visible_media_count`／`latest_thumb_path`／`cover_thumb_path` 三個彙總欄——只算呼叫者依 RLS 看得到的 media | ❌ 沒有寫入語意（view，無 INSERT grant） | ❌ 同上 | ❌ 同上 | `security_invoker=true`，`albums_select`／`album_media_select`／`media_select` 三條既有 policy 逐使用者生效，取代 client 端 `album_media(count)` 內嵌 aggregate 的連結列計數口徑（LS-165 R2），見 §3「albums / diaries」 |
| `album_children`（LS-121） | 我所屬家庭，任一角色（含 viewer） | 🔒 **RPC-only**（`set_album_children`，直接 INSERT 已被 revoke） | 🔒 **無 UPDATE 語意**——覆蓋是同一交易內先刪後插，不是對既有列 UPDATE | 🔒 **RPC-only**（`set_album_children`，直接 DELETE 已被 revoke） | 相簿 ↔ 孩子多對多標記，取代舊版 `albums.child_id` 單一欄位；見 §8 |
| `diaries` | 我所屬家庭的日記 | 🔒 **RPC-only**（`create_diary_entry`，直接 INSERT 已被 revoke） | 🔒 **RPC-only**：內容（body／entry_date／寶貝標記）僅作者本人用 `update_diary_entry`；軟刪／還原（`deleted_at`）作者自己的或 owner 任何一篇，皆用 `set_diary_deleted`（直接 UPDATE 已被 revoke） | owner-only（硬刪，policy 未變） | LS-48 收斂：owner 不能像 `albums` 那樣直接改寫別人日記的內容，只能移除。**LS-57**：owner 軟刪的日記，作者無法自行還原（`LS027`），見 §4。**LS-121**：`child_id` 移出本表，寶貝標記併入 `update_diary_entry` 的 `p_child_ids` 陣列參數，見 §4／§8 |
| `diary_media` | 同上 | owner／member | owner／member | owner／member | 同 `album_media` |
| `diary_children`（LS-121） | 我所屬家庭，任一角色（含 viewer） | 🔒 **RPC-only**（`create_diary_entry`／`update_diary_entry`，直接 INSERT 已被 revoke） | 🔒 **無 UPDATE 語意**——覆蓋是同一交易內先刪後插，不是對既有列 UPDATE | 🔒 **RPC-only**（`update_diary_entry`，直接 DELETE 已被 revoke） | 日記 ↔ 孩子多對多標記，取代舊版 `diaries.child_id` 單一欄位；見 §8 |
| `comments` | 我所屬家庭 | 🔒 **RPC-only**（`create_comment`，直接 INSERT 已被 revoke） | 🔒 **RPC-only**：內容（`body`）僅作者本人用 `update_comment`；軟刪／還原（`deleted_at`）作者自己的或 owner 任何一則，皆用 `set_comment_deleted`（直接 UPDATE 已被 revoke） | owner-only（硬刪，policy 未變） | LS-58 收斂：取代 LS-52 的 hybrid 模式，理由與 `diaries` 同型（見 §3「為什麼 albums／comments／diaries 曾經、現在用了不同的寫入模型」）；Viewer 仍能呼叫 `create_comment`／`update_comment`，符合 PLAN §3。**LS-57**：owner 軟刪的留言，作者無法自行還原（`LS027`），見 §4 |
| `reactions` | 我所屬家庭 | 🔒 **RPC-only**（`toggle_reaction`，直接 INSERT 已被 revoke） | ❌ 無 update policy（沒有可改的內容欄位） | 🔒 **RPC-only**（`toggle_reaction`，直接 DELETE 已被 revoke） | LS-58：加入／收回都收斂進 `toggle_reaction`，不再需要呼叫端自己處理 `23505`（見 §4） |
| `device_tokens` | 僅自己的裝置 | ⚠️ 見下方 | 僅自己 | 僅自己 | **換裝置／換帳號登入請務必呼叫 `register_device_token` RPC，不要直接 INSERT／UPSERT**（見 §4） |
| `feed_items` | 我所屬家庭的時間軸 | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | 沒有任何 client 可寫入的路徑，連 grant 都沒有；混排查詢建議走 `get_family_timeline` RPC（見 §4），不要直接 `.from("feed_items")` 拼 keyset 條件。**LS-121**：`child_id` 欄位已移除（一個項目可以標多個孩子，單一欄位不再成立），單寶貝篩選改走 `feed_item_children`（見下） |
| `feed_item_children`（LS-121） | 我所屬家庭的時間軸，依孩子展開 | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | `get_family_timeline` 的 `p_child_id` 篩選查詢引擎，不建議 client 直接查這張表；見 §8 |
| `content_reports` | 自己送出的＋（若是 owner）自家的 | **任何家庭成員**；建議走 `report_content` RPC（去重＋跨家庭檢查，見 §4） | 僅 `status` 欄，owner-only，且只能改成 `resolved`（不能 `dismissed`） | ❌ 無 delete policy | 駁回（`dismissed`）保留給平台方用 `service_role`／Dashboard 處理；owner 也可用 `remove_content_as_owner` RPC 移除內容並連帶標記相關檢舉 resolved |
| `blocked_users` | 僅自己封鎖的名單（`blocker_id = 我`） | 僅自己；建議走 `block_user` RPC（冪等） | ❌ 無 update policy | 僅自己；建議走 `unblock_user` RPC（冪等） | 被封鎖者看不到自己被封鎖；封鎖後對方內容在時間軸／留言／相簿三處查詢一律過濾，見 §3 |
| `join_requests` | 自己送出的申請＋（若是 owner）自家的待審申請 | 🔒 **RPC-only**（`request_join`） | 🔒 **RPC-only**（`approve_join`／`reject_join`／`withdraw_join`） | 🔒 無 delete policy | 沒有任何 client 直接寫入路徑，grant 只有 SELECT |
| `notification_events` | 🔒 **完全不可讀**（成員無 grant 也無 policy） | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | LS-58：推播彙總佇列的資料面，只給 `service_role`（LS-22 的 Edge Function）讀寫；見 §3 |

**寫入路徑小結（給 iOS 呼叫端的心智模型）**：`family_members`／`invites`／`join_requests`／
`diaries`／`comments`／`reactions`／`children`／`diary_children`／`album_children`
九張表**完全不能**用 `.insert()`／`.update()`／`.delete()`（`family_members` 的
`role`／`can_upload` 例外，見上表；`diaries`／`comments` 的硬刪 `.delete()` 仍走
policy 直接允許，見上表；`children` 自 R1 起連硬刪都收回，三種操作對 `children`
**無任何例外**——見上表 `children` 列；`diary_children`／`album_children`
自 LS-121 起是全新的表，一開始就沒有任何直接寫入 grant，見 §8），一律呼叫對應
RPC；`feed_items`／`feed_item_children` 兩張表完全唯讀（`authenticated` 有 `SELECT`
grant，但沒有任何寫入 grant，見上表）；
其餘表可用 PostgREST 的 `.from(...)` 直接讀寫，但每張表都有欄位級或列級限制，寫
超出範圍會拿到 `42501`（grant 層）或該欄位的 `CHECK`/`NOT NULL` 違反碼（policy
通過但值不合法）。

**例外（LS-52，僅 `albums` 適用，**LS-57 R2 起限縮到內容欄位，LS-121 起
`child_id` 移出本表、內容欄位只剩兩個**）：owner 越權 `.update()` 內容欄位
（`title`／`cover_media_id`）不會回 `42501`，而是靜默影響 0 列**——`albums_update`
的 USING 子句只有「建立者本人」這一個分支，owner 對別人的相簿下 `.update()` 這兩欄時，那一列根本不在 USING 比對得到的範圍內，
Postgres 對「比對不上 USING 的列」的標準反應是直接排除、不觸發任何錯誤（跟對一個
不存在的 `id` 下 `.update()` 一樣，`PATCH` 回應是 200 但 body 是空陣列，不是 4xx）。
這**不是** grant 層限制（不會有 `42501`），也不是 `CHECK` 違反（不會有 `23514`）——
呼叫端必須自己檢查回傳的受影響列數／`return=representation` 的內容判斷「這次
`.update()` 到底改到了沒有」，不能假設「沒有丟出錯誤＝改到了」。owner 想對別人的
相簿做事，唯一有意義的操作是移除／還原，要呼叫 `set_album_deleted` RPC（見
§4）——這支呼叫失敗時**會**丟出明確的 `42501`／`LS023`，不會有「靜默 0 列」這種
模稜兩可的結果。**`comments` 不再適用這條例外**：LS-58 把 `comments` 的寫入面整個
收斂成 RPC-only（同 `diaries`），直接 `.update()` 對任何人（含作者本人）都會回
`42501`，不會有靜默 0 列的情況；`set_comment_deleted` 對失敗情境的保證與
`set_album_deleted` 相同。

**`deleted_at`／`deleted_by`／`family_id` 不適用這條「靜默 0 列」例外——LS-57 R2
起這三欄對 `authenticated` 已無 UPDATE 欄位級 grant，任何人（不論是不是 owner、
是不是建立者、改的是不是自己的相簿）直接 `.update()` 這三欄一律 `42501`**，在
PostgreSQL 解析 UPDATE 語句時就被擋下，連 RLS 的 USING 子句都不會被評估到，跟
「這一列不在 USING 比對得到的範圍內」是完全不同的機制（R1 版本時 `albums` 對這
三欄還是整表 grant，owner 對別人相簿的 `deleted_at` 直接 `.update()` 當時確實是
落在上一段的「靜默 0 列」；R2 的欄位級收斂把這個行為統一改成明確的 `42501`，
不論呼叫者是誰）。想軟刪／還原相簿，唯一路徑是 `set_album_deleted` RPC（見
§4）——這支呼叫失敗一樣有明確錯誤碼（`42501`／`LS023`／`LS027`），不會有「靜默
0 列」或「猜不到到底改到了沒」的情況。

**過渡期擋寫（LS-151，R2 訂正範圍）**：`profiles.deletion_requested_at` 非
`NULL`（呼叫過 `delete_my_account()`、還沒被 Edge Function `delete-account` 真正
刪除 `auth.users` 的窗口期）時，`families`／`media`／`diaries`／`albums`／
`children`／`comments`／`join_requests` 七張表的 `INSERT` 一律拒絕（`LS051`），
`family_members` 額外擋 `UPDATE OF role, user_id`——不論走的是直接 `.insert()`
還是任何 `SECURITY DEFINER` RPC（`create_child`／`create_diary_entry`／
`create_comment`／`approve_join`／`request_join`／建立新家庭時自動寫入 owner 的
內建 trigger 皆同）——見 §「Edge Functions」。這是**第二道防線**（縱深防禦），
`family_members`／`join_requests` 的 guard 查的是「被寫入的人」而不是操作者的
`auth.uid()`（R2 訂正 merge-review R1 B1）。第一道、真正保證「刪除一定成功」的
是 §「Edge Functions」`finalize_account_deletion()`。這**不是**額外的權限收斂，
是暫時性的帳號狀態拒絕：`deletion_requested_at` 清除（帳號真的被刪、`profiles`
隨 `auth.users` cascade 消失）之後這個限制自然不存在，不會有任何一個仍在使用中
的帳號撞到這個碼。

---

## 3. 逐表細節

以下只列**呼叫端會直接用到**的欄位語意；完整欄位型別以 `supabase/migrations/20260822120000_init_schema.sql`
與 `20260823010000_join_approval.sql` 為準。

### `profiles`
- `id`＝`auth.users.id`。**由 `auth.users` 的 AFTER INSERT trigger
  （`private.handle_new_auth_user()`，LS-110）自動建立**，登入流程不需要、也不應該
  自己 `insert` 一列——`display_name` 由 `private.derive_display_name()` 正規化
  推導：依序取 `raw_user_meta_data->>'full_name'`、`->>'name'`、email 帳號部分，
  每個候選先去頭尾空白再截斷到 50 字，空字串／全空白視同沒有該候選；三者都落空時
  保底 `新成員`（永遠非空、永遠 ≤ 50 字，不會撞 `profiles_display_name_check`）。
  `avatar_url` 取 `raw_user_meta_data->>'avatar_url'`（去空白後為空字串也視為
  `NULL`）。client 只做 `update`（改自己的 `display_name`／`avatar_url`）；INSERT
  grant 與 `profiles_insert` policy 仍在（未被 revoke，LS-107 `ensureProfileExists`
  的冪等 upsert 靠它）。**trigger／回填都只 `insert`、不 `update`**——既有列的
  `display_name` 永遠不會被回填或之後的觸發再覆寫（trigger 已建過的使用者不會二次
  觸發；回填只補「缺列」；兩者都用 `on conflict (id) do nothing`），即使 client 先
  以 `ensureProfileExists` 建了一列、`display_name` 停在 email 帳號部分，也不會被
  之後任何流程改掉，需要使用者自己透過 `update` 改名。
- 只看得到：自己 ＋ 與自己同家庭的人（`private.peer_profile_ids()`）。陌生使用者的
  `display_name`／`avatar_url` 不會外洩。
- `deletion_requested_at`（LS-143）：`delete_my_account()` 成功後寫入，`NULL`＝
  未請求刪除。**client 對這一欄沒有 `UPDATE` 權限**（欄位級 grant 收斂，直接
  `.update()` 一律 `42501`）——`authenticated` 對 `profiles` 原本是整表 `UPDATE`
  grant，本欄新增時已改成「先收回整表、只重開 `display_name`／`avatar_url`」，見
  `20260903084231_delete_account.sql` 檔頭；只能透過 `delete_my_account()` 寫入。
  這一欄只是**資料面的請求標記**，不是刪除本身——`auth.users` 的實際刪除（連帶
  cascade 掉這一列）由另一支以 `service_role` 執行的流程完成（Edge Function
  `delete-account`，LS-151，見 §4 `delete_my_account`與§「Edge Functions」）。
  `service_role` 對這張表只有欄位級 `grant select (id, deletion_requested_at)`
  （LS-151 R2 收斂範圍，merge-review R1 i1，`20260903115014_delete_account_edge_support.sql`）
  ——Edge Function 與 `finalize_account_deletion()` 只需要讀這兩欄判斷是否放行，
  沒有寫入需求，也不需要整表 SELECT。
- `suspended_at`（LS-179，PLAN §10-B）：**client 讀得到、改不動**——`authenticated`
  對 `profiles` 是表級 SELECT grant（見上方），新欄位自動被涵蓋，停權事實本來就
  會從每一次操作失敗的 `LS052` 揭露，這裡讀得到不算額外資訊洩漏；UPDATE 沒有
  這一欄的 grant，只有表擁有者（postgres，Dashboard／`db query --linked`）能寫。
  非 `NULL` 時，這個使用者對「所有」家庭資料的讀寫與既有 RPC 入口一律拒絕
  （`LS052`），但**自己的 `profiles` 列不受影響**——他仍然看得到、改得動自己的
  `display_name`／`avatar_url`（範圍決策，理由見 migration
  `20260904212530_suspension_and_registrations.sql` 第 3 段）。**停權原因**
  （稽核用）**不放在這張表上**——`authenticated` 是表級 SELECT，任何欄位都會
  被自動涵蓋，稽核原因（可能含第三方個資）不能讓被停權者自己讀得到；原因存在
  `private.suspension_notes`（只有表擁有者，postgres；`service_role` 若日後
  需要須另外 grant——目前零 grant，同 `service_role` 對 `app_settings`／
  `profiles`／`families` 的既有慣例，R2，merge-review R1 MAJOR-1，n3 訂正）。
  停權操作方式見
  §11。
- `eula_accepted_version`／`eula_accepted_at`（LS-197，PLAN §6 第 7 項／
  §10-B）：使用者最近一次同意 EULA 的版本與時間，`NULL`＝從未同意過。**client
  讀得到、改不動**——理由同 `suspended_at`／`deletion_requested_at`：
  `authenticated` 對 `profiles` 的 `UPDATE` grant 早就收斂成只開
  `display_name`／`avatar_url` 兩欄（LS-143），這兩個新欄位天生不在允許清單
  內，只能透過 `accept_eula()`（見 §4）寫入。同意紀錄可稽核：兩欄一經寫入即
  保留最近一次同意的版本與時間戳，不會被 client 竄改。

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
  app 後必須能自建家庭），但會被下面兩個旗標擋下（LS-179）：呼叫者已被停權
  （`LS052`）或 `app_settings.registrations_open = false`（`LS054`，PLAN §10-A(3)）。
  **只擋這條自建路徑**——憑邀請碼加入既有家庭（`request_join`／`approve_join`）
  完全不碰 `families` 表，不受 `registrations_open` 影響。
- `suspended_at`（LS-179，PLAN §10-B）：client 讀得到、改不動，理由同
  `profiles.suspended_at`。非 `NULL` 時，這個家庭的全部成員（不分角色，**含
  建立者本人**——R2 merge-review m2 訂正：`families_select` 的 `created_by`
  分支原本漏了這個判斷，建立者即使本人未被個別停權，家庭停權後仍能透過那個
  分支看到 1 列）對這個家庭的資料一律拒絕讀寫（`LS053`）；成員對「其他」家庭
  不受影響。停權原因不放在這張表上，同樣存在 `private.suspension_notes`。
  停權操作方式見 §11。

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
- `code`：**6 碼**（LS-90，LS-89 裁決 A；原為 8 碼，見下方「LS-90 變更說明」）、
  大寫、字元集 `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（拿掉 `0/O/1/I`）——32 字元＝
  2 的冪，每碼滿的 5 bits，6 碼合計 30 bit 熵。
- `max_uses`／`used_count`：次數在「申請成立」（`request_join` 呼叫成功）時就消耗，
  **不是**核准時才扣；拒絕／撤回不退還次數。

**LS-90 變更說明（2026-08-25，LS-89 使用者裁決 A）**：邀請碼長度 8→6，字元表不變。
LS-46 使用者定案本來就是「邀請碼英數 6 碼」，LS-33 落地時誤植成 8 碼／40 bit
（正式站已部署）；LS-30 PR #136 review 發現這個落差，LS-89 裁決改後端配合定案。
**既有未過期的邀請碼在這支 migration
（`supabase/migrations/20260825070627_invite_code_6.sql`）套用時一律失效**
（`update invites set expires_at = now() where expires_at > now()`）——正式站當時
沒有真實家庭在使用邀請碼，用失效（改 `expires_at`）而不是刪除，稽核紀錄與底下
已核准／拒絕的 `join_requests` 都保留。`request_join` 沒有變動：它本來就不對
輸入碼做長度／格式檢查，直接交給既有的三段檢查分流，這對 8 碼舊格式碼會有兩種
結果（R1 F1 訂正）：**曾經真實存在、被上面那句 UPDATE 標記過期的列**（列還在，
只是 `expires_at` 已是過去）→ 找得到列但已過期 → `LS011`；**從來沒被
`create_invite` 產生過的字串**（單純打錯或亂猜）→ 查無此列 → `LS010`（見 §4）。

### `children`
- `family_id, id` 有複合 UNIQUE，供 `albums`/`diaries` 的複合外鍵綁定同家庭。
- 一個 family 可以有多個 children（1 家庭 : N 孩子），見 §8。
- **寫入面 RPC-only（LS-66）**：新增用 `create_child`（owner／member 皆可）、編輯用
  `update_child`（owner／member 皆可，仍是該家庭成員才行，被降級成 viewer 之後不能
  再編輯）、軟刪／還原用 `set_child_deleted`（**僅 owner**，比 `create_child`／
  `update_child` 窄——刪除是比新增／編輯重的破壞性動作）。直接 `.insert()`／
  `.update()` 一律 `42501`（見 §2）。**硬刪路徑不存在**（R1 I5）：`children_delete`
  policy 已改成一律拒絕、`DELETE` grant 也收回，連 owner 都沒有直接
  `.delete()` 的路徑——原本 owner-only 的直接硬刪會繞過 30 天可還原的保護（把整列
  連 `diary_children`/`album_children` 底下掛著的標記一起清光），LS-47 定案的硬刪流程本該
  走 §10 破壞性流程，不該是這裡順手留下的後門。「30 天後真正怎麼清除或永久保留」
  留給排程票，屆時若要開放硬刪，須是那張票另外設計、走 §10 授權。
- **`family_id` 建立後不可變**：`update_child` 的參數本來就不含 `family_id`，另外
  還有一支 DB trigger（`children_family_immutable`）做二次防護——任何試圖改動
  `family_id` 的 UPDATE 都會被擋下（`42501`；LS-57 R2／I1 對齊，原本的專屬碼
  `LS040` 已撤，改用跟 `diaries`／`albums`／`comments` 一致的裸 `42501`），即使
  未來的 RPC 改版不慎誤寫也擋得住。
- **軟刪＝30 天內可還原**（`deleted_at`／`deleted_by`，LS-66；LS-47 定案第④題）：
  `set_child_deleted(p_deleted = true)` 軟刪；`p_deleted = false` 還原，但
  **`deleted_at` 超過 30 天前會被拒絕（`LS043`）**——30 天後的實際清除／保留策略
  留給排程票，本票只做「30 天內可還原」這個邊界語意，RPC 層面就先擋，不留給 UI
  自己判斷時限。**重複軟刪是 no-op**（R1 I1/I2）：對已經是軟刪狀態的孩子再次呼叫
  `set_child_deleted(true)`，`deleted_at`／`deleted_by` 完全不變，不會刷新時間戳
  （否則 owner 可以無限延後 30 天邊界）也不會把歸屬洗成這次呼叫者（語意對齊 LS-57
  對 `diaries`/`albums`/`comments` 的 `deleted_by` 推導規則）；只有「從 active 到
  已軟刪」這一次真正的轉換才寫入新值，還原後再重新軟刪才會重新計時、重新歸屬。
  **照片／日記掛在這個孩子底下的既有標記不會隨軟刪連動**（LS-121 起標記住在
  `diary_children`／`album_children` 連結表，不是 `albums`/`diaries` 本體的單一
  欄位）——既有標記列完全不受影響，繼續存在、繼續可讀，那些日記／相簿也仍可繼續
  軟刪／還原／編輯自己（見 §8）；但**已軟刪的孩子不能再被指定為新內容的標記**——
  `diary_children`/`album_children` 各有一支 `BEFORE INSERT` trigger，凡是要新增
  一列標記、且指向的孩子已軟刪（新建立內容時指定，或既有內容改標記到別的已軟刪
  孩子），一律拿 `LS044`（R1 I3；LS-121 起守門搬到連結表，函式沿用不變）。
- **軟刪旗標的可見性**：**不分角色、不分軟刪與否**——同家庭的 owner／member／
  viewer 都讀得到全部列，含已軟刪的（`deleted_at`／`deleted_by` 對所有人都是可見的
  唯讀旗標，不論是直接 `.from("children").select()` 還是呼叫 `list_children`）；
  只有「還原」這個**動作**收斂在 `set_child_deleted` 的 owner-only 授權檢查裡，不是
  靠 RLS 擋讀取（R1 I3/I4，merge-reviewer PR #95 review：`get_family_timeline`／
  `feed_items` 對軟刪孩子的行為完全不變，若讀取權限收斂成僅 owner 可見，
  member／viewer 會拿到自己解不開的 `child_id`，見 §8 的呼叫端契約）。
- **輸入驗證碼（R1 I6）**：`create_child`／`update_child` 對 `name`（1–50 字，
  `children_name_check`）與 `birthday`（`NOT NULL`）沿用表本身既有的 `CHECK`／
  `NOT NULL` 約束——不合法的輸入不是拿到自訂 `LSnnn` 碼，是直接從 RPC 內部的
  `INSERT`/`UPDATE` 冒出標準 `23514`/`23502`（見 §5 標準碼表；雖然 `children` 已是
  RPC-only、不是「允許直寫的表」，但 RPC 參數映射進 `INSERT`/`UPDATE` 撞到表上的
  `CHECK`/`NOT NULL` 時，冒出來的仍是同一組標準碼，呼叫端的處理方式不變）。

### `media`
- `storage_path` 必須符合 `{family_id}/{yyyy}/{mm}/{media_id}.{ext}`（見 §6），且有
  `CHECK` 強制前綴＝`family_id`。
- **縮圖三欄（`thumb_path`／`thumb_width`／`thumb_height`，LS-128）**：皆 nullable，
  三欄同為 `NULL` 或同為非 `NULL`（`media_thumb_dimensions_consistency` `CHECK`）——
  沒有縮圖的過渡期列（既有資料、縮圖產生失敗）三欄留空即可，讀取端退回原圖
  `storage_path`（見 §6「簽名 URL 與 egress 防線」）。`thumb_path` 有值時同樣受
  `CHECK` 強制前綴＝`family_id`，且 `UNIQUE`（`media_thumb_path_key`）；
  `thumb_width`／`thumb_height` 有值時必須 `> 0`。**三欄一旦隨 `INSERT` 寫入即不可
  再 `UPDATE`**（無欄位級 grant，同 `storage_path`／`byte_size`）——不存在「先建
  `media` 列、之後才補上縮圖」的合法路徑，見下一點的上傳流程順序。**代價**：以
  `thumb_path` 為 `NULL` 寫入的列（縮圖產生失敗、或既有舊資料）在目前的欄位級 grant
  下，**客戶端沒有合法路徑事後補寫縮圖**——只能永遠退回原圖（見 §6「簽名 URL 與
  egress 防線」）。日後若要支援「事後補縮圖」，需要一支新的非破壞性 migration 開放
  `update (thumb_path, thumb_width, thumb_height)` 欄位級 grant，並用 trigger 限制只
  允許 `NULL → 非 NULL` 的單向轉換（否則會連帶放掉 `storage_path` 等級的不可變保證）。
- **上傳流程順序很重要**：Storage 物件與 `media` 列是兩份獨立資料，DB 不會替你保證兩者
  一致。正確順序：① 先把原始檔案 PUT 進 Storage（`storage.objects`，見 §6）
  ② **同步產生縮圖並 PUT 進 Storage**（長邊 ≤ 512px、JPEG 品質 0.8；影片取首幀轉成同
  規格 JPEG；路徑 `{family_id}/{yyyy}/{mm}/{media_id}_thumb.jpg`，見 §6）——①②互不
  相依（縮圖只需要本機解碼後的圖像資料，不需要等原檔上傳完成），**可以並行 PUT**
  （例如 `async let`／`TaskGroup`，佇列量大時搭配並發上限），不必序列化跑——③ 兩者皆
  成功後才 `insert` 對應的 `media` 列（`storage_path`／`thumb_path`／`thumb_width`／
  `thumb_height` 一次寫入，不分兩次）。若①②任一步失敗就不要 `insert`；若第③步因
  `LS002`（額度爆了）或其他原因失敗，**已經上傳的 Storage 物件（原檔與縮圖）都會變成
  孤兒**——上傳者對自己剛上傳的物件有 Storage `DELETE` 權限（見 §6），失敗時 client
  自己要清掉，DB 不會幫你清。**縮圖產生失敗但原檔上傳成功時**：不阻斷整體上傳——
  `thumb_path`／`thumb_width`／`thumb_height` 三欄留空插入 `media` 列即可（過渡期
  退回原圖，語意與既有無縮圖的舊資料一致），不需要重試整個上傳。
- **影片時長（`duration_seconds`，LS-134）**：nullable，`CHECK`（有值時必須 `> 0`，
  `media_duration_seconds_positive`）。`type = 'photo'` 時應留 `NULL`；
  `type = 'video'` 時由上傳端以 `AVAsset.load(.duration)` 量測寫入——**若影片經過
  裁切，以裁切後的長度為準**，不是原始檔案的長度。整數秒，**`max(1, floor(d))`**
  （`d` 為量測到的秒數：不足 1 秒的影片記為 1，不進位、不寫 0）——**與
  `VideoDurationFormat`／`DiaryDurationFormat` 同源**：merge-review R1 i2 裁定
  「`M:SS` 是給人看的粗略時長，不是精確時間戳，捨去比進位更符合『這支影片還有多
  長』的直覺」，這裡沿用同一個取整方向，同一支影片在日記編輯器與時間軸卡片才會
  顯示同一個數字（見 `LittleSprout/Support/VideoDurationFormat.swift`／
  `DiaryDurationFormat.swift` 檔頭）。**量測失敗、或量到的長度 `≤ 0` 秒時，留
  `NULL`，不得寫 `0`**——`0` 會被 `media_duration_seconds_positive` 擋下，而此時
  原檔與縮圖多半已依「上傳流程順序」PUT 進 Storage 完成，`INSERT` 才失敗會留下
  兩個孤兒物件；留 `NULL` 走的是既有的過渡路徑（§6「`NULL` 退回純文字『影片』」），
  不會失敗。DB 只驗「有值時必須 `> 0`」，**不驗與 `type` 的相依關係**——既有
  video 列在本欄位新增當下（LS-134 migration 套用時）皆為 `NULL`，加一條「video
  必填」的 `CHECK` 會讓既有列直接違反約束，因此這條相依關係是**上傳端契約義務**，
  不是機械可驗證的資料庫不變量；日後若要補這條約束，需要先回填既有 video 列。
  **一旦隨 `INSERT` 寫入即不可再 `UPDATE`**（無欄位級 grant，同
  `storage_path`／`thumb_path`）。
- `byte_size` 是 `families.storage_used_bytes` 額度計算的唯一依據（`media` 表的
  statement-level trigger 依 `byte_size` 加總），**不是**看 Storage 物件實際大小。
  這代表：如果 client 上傳到 Storage 的檔案大小與 `media.byte_size` 填的值不一致，
  額度計算會跟著算錯——`byte_size` 必須填實際上傳的位元組數。
- soft delete（`deleted_at`）立刻釋放額度；硬刪只有 owner 能做。
- **`media_select` 過濾 `deleted_at`，上傳者例外（LS-155 R2，merge-review R1 M2
  實測補上）**：
  `using (family_id in (select private.family_ids()) and (deleted_at is null or
  uploaded_by = auth.uid()))`——軟刪的 media 對其他家庭成員直接在 RLS 層消失，
  不論是獨立照片卡（本來就靠 `feed_items` 消失）、日記附帶、還是相簿封面（這兩
  條路徑不經過 `feed_items`，R1 版本沒有這條 policy 時仍會繼續顯示，見
  `20260904080921_media_select_hide_deleted.sql` 檔頭的實測情境）。**上傳者例外
  不是可省的細節，是這支 policy 能存在的前提**：`media_update` 對
  `authenticated` 是欄位級 grant（只開 `taken_at`／`deleted_at`／`width`／
  `height`），PostgreSQL 對欄位級 UPDATE 授權的表，要求 UPDATE 之後的新列也必須
  通過該表的 SELECT policy（`ExecWithCheckOptions`，本機小型 repro 表驗證過：
  整表 UPDATE grant 不會觸發、欄位級 grant 會）——若 `media_select` 單純加
  `deleted_at is null`（不含例外），上傳者對自己照片呼叫
  `UPDATE media SET deleted_at = now()`（既有「收回自己的照片」路徑）這句話本身
  就會直接被 RLS 拒絕，本機 `supabase/tests/20_role_permissions.sql` 的正向對照
  段落當場炸掉，逼出這個例外（見 migration 檔頭完整記錄）。**已知殘留缺口
  （LS-155 R2 review i1／m1 訂正過一次措辭）**：`media_update`／`media_delete`
  也允許 owner 分支（處理「任何一張」，見下一點），但 `media_select` 的例外只
  覆蓋 `uploaded_by = auth.uid()`——owner 若直接對**別人**上傳、已軟刪的照片以
  **欄位級 grant 的直接 UPDATE／DELETE**操作（不經過任何 RPC），UPDATE 會撞
  `ExecWithCheckOptions` 而失敗、DELETE 會因為找不到列而**靜默影響 0 列**（R2
  review m1 實測，`P7`）。**訂正（R2 review i1）**：這不需要「另開一支 RPC」
  ——`public.remove_content_as_owner('media', id)`（LS-23，見 §4）早就是 owner
  moderation 的正確路徑，`SECURITY DEFINER`、繞過 RLS，R2 review 實測（`P8`）
  新 policy 生效後仍正常運作；壞掉的只是**次要、legacy** 的欄位級直接
  UPDATE／DELETE 路徑，目前沒有任何測試或 client 程式碼行使（`grep -rn
  deleted_at LittleSprout/` 只命中 `children`）。記入 LS-96 待辦池（`5cd11293`）：
  不急，兩個選項皆可——維持現狀（legacy 路徑靜默失效，無 client UI 不影響任何
  人）或未來把 `media_update`／`media_delete` 的 owner-對-別人分支拿掉、統一走
  `remove_content_as_owner()`。`purge_expired()`／`media_storage_sync()`／
  `delete_my_account()`／`finalize_account_deletion()`／
  `remove_content_as_owner()` 對 `media` 的讀寫皆為 `SECURITY DEFINER`（以表
  擁有者身分執行），RLS 對它們天生不生效，不受這支 policy 影響。
- **`media_update` policy 的上傳者分支判斷「當下」而不是「上傳當時」是否有上傳權**
  （`family_id in uploadable_family_ids()`，跟 §6 storage.objects 的規則同一個判準）：
  owner 把某個 member 的 `can_upload` 關掉之後，那個人（若不是 owner）連軟刪除
  （`update ... set deleted_at = now()`）自己以前上傳的照片都會被拒，拿到 `42501`
  ——不是「刪不到別人的」，是「刪不到自己的」。想清掉自己上傳的內容，要嘛先請 owner
  恢復 `can_upload`，要嘛請 owner 出手處理（owner 分支不受這個限制）。

### `albums` / `diaries`
- **相簿列表請讀 `album_summaries`（LS-200），不要用 client 端內嵌 aggregate 算張數**：
  `album_summaries` 是一支 `security_invoker=true` 的 view，逐本相簿多帶三個彙總欄——
  `visible_media_count`（呼叫者依 RLS 看得到的照片數）、`latest_thumb_path`（依
  `created_at` 排序、可見範圍內最新一張的縮圖路徑）、`cover_thumb_path`（`cover_media_id`
  指到的那張縮圖路徑，若該張已軟刪／跨家庭則為 `NULL`）。`security_invoker=true`
  讓 view 內部對 `albums`／`album_media`／`media` 的存取套用呼叫者本人的 RLS
  （`albums_select`／`album_media_select`／`media_select`），跨家庭隔離、軟刪過濾
  （含 `media_select` 的上傳者例外，見上方 `media` 表）皆沿用既有 policy，不在 view
  裡重複判準。欄位與 `albums` 表其餘部分完全一致（含 `id`／`created_at`，keyset
  分頁條件照舊可用），grant 只開 `authenticated` 的 `SELECT`，`anon` 沒有。
  **取代的舊口徑**：iOS 相簿 tab 列表原本讀 PostgREST 內嵌 aggregate
  `album_media(count)` 算張數——那數的是 `album_media` 連結列本身，不是「使用者
  看得到的照片數」，已被軟刪或（LS-155 刪帳號後）`uploaded_by` 被清空的 media
  仍會被算進「N 張」（LS-165 R2 merge-review m3）；`album_summaries` 是那個口徑
  差異的正式修法，`SupabaseAlbumsAPIClient` 改讀本 view 屬於另一張 iOS 票（不在
  LS-200 範圍，見 LS-200 票文「不做」段）。
- **寶貝標記自 LS-121 起是多對多**（見 §8 完整說明）：一篇日記／一本相簿可以標
  0～N 個孩子，透過 `diary_children`／`album_children` 連結表表達，不再是
  `albums.child_id`／`diaries.child_id` 這種單一欄位（兩欄已隨 LS-121 移除）。
  複合外鍵綁同一家庭，跨家庭的孩子 id 一律 `23503`；已軟刪的孩子一律 `LS044`
  （見 §8）。
- `albums`（LS-52 起，見 §2 表與下方「三套寫入模型」；LS-57 R2 起，`deleted_at`／
  `deleted_by`／`family_id` 三欄的寫入路徑收斂；LS-121 起 `child_id` 移出本表，
  見下）：
  - 內容（title／cover_media_id）僅建立者本人（仍是該家庭 owner/member）
    直接 `.update()`；owner 對別人建立的相簿**沒有**改寫內容的路徑（連「靜默 0 列」
    都沒有其他分支可用，見 §2「寫入路徑小結」的例外說明）。這兩欄不受下面的欄位級
    grant 收斂影響，維持 LS-52 定案的 hybrid 模式。寶貝標記（`album_children`）
    是獨立的第三條路徑，唯一入口是 `set_album_children` RPC（見 §4），授權門檻
    跟內容欄位的建立者分支一致（仍是該家庭 owner/member 的建立者本人），不是
    owner 的移除／還原權限。
  - **軟刪／還原（`deleted_at`）自 LS-57 R2 起是 RPC-only**：`set_album_deleted`
    （見 §4）是唯一路徑，建立者與 owner 皆同——直接 `.update({deleted_at: …})`
    不論改的人是誰、改成什麼值，一律 `42501`（欄位級 grant 收回，見下）。R1 版本
    原本讓建立者能直接 `.update()` 軟刪／還原自己的相簿（`.update()` 與 RPC 兩條
    路徑並存），merge-reviewer PR #98 review R2（N1／N2 blocker）指出這條直接
    UPDATE 路徑讓呼叫端的 UPDATE 語句碰得到 `deleted_by`／`family_id` 這些治理
    欄位，trigger 補不了「同一句 UPDATE 想夾帶什麼」——唯一根治的施力點是欄位級
    grant，代價是建立者也一併失去直接 `.update()` 軟刪／還原自己相簿的路徑，
    改用 `set_album_deleted` RPC（授權範圍已經涵蓋建立者自己的相簿，只要求仍是
    該家庭任一角色的成員，被降級成 viewer 也適用，F5：對齊 `diaries`／`comments`
    的同名 RPC，見 §4）——功能不變，只是唯一路徑從「兩條選一條」收斂成「一條」。
  - 硬刪（真正 `DELETE` 整列）仍是 owner-only 的直接 policy，未被收斂進 RPC，
    不受本次收斂影響。
  - **`deleted_by`／還原鎖**：`deleted_at` 被誰設下，由
    `private.enforce_deletion_attribution()` trigger 記在新欄位 `deleted_by`
    （**無法透過 `UPDATE` 指定**——R2 起這一欄同樣無 UPDATE 欄位級 grant，見下。
    `INSERT` 方向不受影響：`albums` 對 `authenticated` 仍是整表 INSERT grant，
    建立者技術上可以在新增時自己塞一個 `deleted_by` 值，但 `albums_insert` 的
    WITH CHECK 是 `created_by = auth.uid() and family_id in
    contributor_family_ids()`，只能在自己所屬的家庭、以自己的名義新建一列，這一列
    本來就歸他處置——不構成越權，只是稽核欄位可能被自己填成任意值，見 §4
    `set_album_deleted` 的同一則說明，merge-reviewer PR #98 review R3 F4）。
    建立者只能還原（或重新觸碰）`deleted_by` 是自己的
    `deleted_at`；owner 軟刪的，建立者呼叫 `set_album_deleted` 一律拿 `LS027`。
    **owner 後手移除＝歸屬升級**：owner 對一本已經被建立者自刪的相簿再次移除
    （或還原），`deleted_by` 會改寫成 owner 自己，不會維持建立者不變——owner 的
    動作永遠是最新、最權威的一次，建立者不能靠「先自刪一次」讓歸屬停留在自己
    名下、之後還能自行還原。`deleted_by` 為 `NULL` 有兩種成因：（a）本欄位新增
    之前就已軟刪除的既有資料，或（b）移除者的帳號後來被刪除（`deleted_by` 的 FK
    是 `on delete set null`，帳號刪除的 RI 動作會清成 `NULL`，這支 trigger 特別
    放行這個動作本身，不會讓帳號刪不掉）——兩種情況都視為「移除者不明」，**只有
    owner 能還原**，不是「任何人都能還原」（不再是 LS-57 初版的行為）。
  - **`family_id` 不可變**：R2 起 `authenticated` 對 `family_id` 已無 UPDATE 欄位級
    grant，建立者直接 `.update({family_id: …})` 一律 `42501`（grant 層擋下，
    不會走到 RLS 或 trigger）；`private.enforce_deletion_attribution()` trigger
    仍然保留同一條檢查，作為繞過 grant 的路徑（SECURITY DEFINER RPC、表擁有者
    身分執行的寫入）的第二道防線——`albums_update` policy 本身只檢查「改完之後
    的 `family_id` 是不是自己也是 contributor 的家庭」，沒有檢查「這欄有沒有
    被動過」，這件事不是 policy 能表達的規則，見 migration 說明。
- `diaries`（LS-48 起，見 §2 表與 §4 三支 RPC）：
  - 新增／編輯內容／軟刪都是 **RPC-only**，直接 `.insert()`／`.update()` 一律 `42501`
    （`comments` 自 LS-58 起也是這個模式，見 §3「comments / reactions」段；
    `albums` 的內容欄位仍是唯一保留直接 `.update()` 的例外，見上方，但其
    `deleted_at`／`deleted_by`／`family_id` 三欄自 LS-57 R2 起也已收斂成
    RPC-only／不可變）。
  - Owner 對別人日記**只有軟刪權**（`set_diary_deleted`），**沒有**編輯內容的權限。
  - 硬刪（真正 `DELETE` 整列）仍是 owner-only 的直接 policy，未被收斂進 RPC。
  - **`deleted_by`／還原鎖（LS-57）**：規則同上（albums 段，含 owner 後手移除的
    歸屬升級、`deleted_by` 為 `NULL` 一律 owner-only 還原），差別只在 `diaries`
    唯一寫入路徑是 `set_diary_deleted` RPC——沒有直接 `.update()` 這條路可以踩，
    `family_id` 也因此已經不可能被移動（`update_diary_entry` 簽章本來就不接受
    `family_id` 參數），trigger 對 `diaries` 是額外一層防線，不是解決一個當下真的
    存在的入口，見 migration 說明。

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
3. **`albums`（hybrid 模式，LS-52；LS-57 R2 起 hybrid 範圍縮小，見下方追記）**：
   跟 `diaries`／`comments` 是同一種洞
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

   **LS-57 R2 追記（merge-reviewer PR #98 review N1／N2）**：上面「owner 分支不限
   欄位」的洞修好之後（LS-57 R1，trigger 記 `deleted_by`），R2 review 又實測出
   hybrid 模式本身的第二層問題——建立者的直接 `.update()` 路徑一樣能碰到
   `deleted_by`／`family_id` 這兩個治理欄位（`albums_update` policy 的 WITH CHECK
   從來沒檢查過這兩欄），trigger 補不了「同一句 UPDATE 想塞什麼」。這次改用
   column-level grant 收斂：`deleted_at`／`deleted_by`／`family_id` 三欄收回
   UPDATE grant（只留 RPC／trigger 可寫），`title`／`child_id`／`cover_media_id`
   三欄維持 hybrid。當時「column-level grant 表達不出依列而異的欄位集合」這個
   否決 RPC-only 全面收斂的理由**依然成立**——這次不是要在同一個 grant 裡表達
   「作者能動全部、owner 只能動 `deleted_at`」，而是把「內容」與「治理」兩組
   欄位切開、各自套用單一、不分列的規則（內容欄位對建立者開放、治理欄位對
   authenticated 整體關閉），這正是 column-level grant 物理上表達得出來的形狀，
   跟 `media`／`families` 的既有先例同一種道理，不是走 RPC-only 那條路。

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

### `diary_children` / `album_children`（LS-121）
- 日記／相簿 ↔ 孩子的多對多標記，取代舊版 `diaries.child_id`／`albums.child_id`
  單一欄位（1:N，一篇內容最多對一個孩子）——見 §8 完整說明。
- 純連結表，自帶 `family_id`（同 `album_media`/`diary_media`，policy 不必 join 回
  `diaries`/`albums`/`children`）；兩條複合外鍵確保「A 家的日記掛 B 家的孩子」在
  DB 層建不起來，跨家庭一律 `23503`。
- **RPC-only**：直接 `.insert()`/`.update()`/`.delete()` 對 `authenticated` 一律
  `42501`（這兩張表從一開始就沒有任何直接寫入 grant，不是像 `diaries` 那樣後來
  才收斂）。`diary_children` 唯一寫入路徑是 `create_diary_entry`／
  `update_diary_entry`；`album_children` 唯一寫入路徑是 `set_album_children`
  （見 §4）。沒有 UPDATE 語意——「改標記」是同一交易內先刪掉多的、再補上少的
  （「刪多補少」），不是對既有列 `UPDATE`。
- 讀取（SELECT）對同家庭任一角色開放，含 viewer——跟 `children` 本身的可見性
  一致（§3 `children` 段：讀取不分角色，只有動作限角色）。
- **LS044 守門**：任何一列的 `child_id` 指向一個已軟刪的孩子，INSERT 一律
  `LS044`（`BEFORE INSERT` trigger，見 §8）。

### `feed_item_children`（LS-121）
- `get_family_timeline` 的 `p_child_id` 篩選查詢引擎（見 §8「時間軸的多寶貝篩選」）
  ——一個時間軸項目標記 N 個孩子就有 N 列，`(kind, ref_id, child_id)` 三欄唯一。
  完全由 trigger 維護（同 `feed_items` 自己的既有慣例），`authenticated` 只有
  `SELECT`，沒有任何寫入 grant。
- 不建議 client 直接查這張表——它是 `get_family_timeline` 內部用來走索引的實作
  細節，不保證欄位形狀不會再變；要看時間軸請一律呼叫 `get_family_timeline`。

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
  `set_comment_deleted` RPC（見 §4，LS-52 建立），對內容沒有任何直接寫入路徑。
  **`deleted_by`／還原鎖（LS-57）**：規則同 `diaries`（含 owner 後手移除的歸屬
  升級、`deleted_by` 為 `NULL` 一律 owner-only 還原）——唯一寫入路徑是
  `set_comment_deleted` RPC，`deleted_by` 由 `private.enforce_deletion_attribution()`
  trigger 記錄，作者只能還原自己設下的、owner 軟刪的作者無法自行還原（`LS027`，見
  §4）。`family_id` 同樣已經不可能被移動（`update_comment` 簽章不接受 `family_id`
  參數），trigger 的 `family_id` 不可變檢查對 `comments` 同樣是額外一層防線。
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
  暴露寶貝篩選能力的入口。
- **LS-121 起沒有 `child_id` 欄位**——LS-48 曾經加過的單一 `child_id` 欄位已移除
  （一個項目可以標多個孩子，單一欄位的資料模型不再成立）。`get_family_timeline`
  回傳的 `child_ids uuid[]` 改由 `diary_children`／`album_children` 動態聚合，
  `p_child_id` 篩選改走 `feed_item_children`（見 §8）。`media` 類項目的
  `child_ids` **恆為空陣列**——`media` 本身不直接關聯任何孩子，只能透過
  `album_media` 間接、多對多地關聯到相簿的孩子標記，無法唯一決定歸屬。實際影響：
  `get_family_timeline` 的 `p_child_id` 篩選為指定值時，`media` 類項目**不會
  出現**；只有 `p_child_id = NULL`（查全部）時才看得到。

### `notification_events`
- **推播彙總佇列**——資料面（LS-58：來源 trigger、彙總視窗、合併鍵）與發送面（LS-172：
  `sent_at` 由誰、何時、以什麼語意寫入）合記在這裡，**iOS client 完全不會呼叫這張表**
  （沒有任何 grant，見下）。發送邏輯本體（決定通知對象、組文案、呼叫 APNs）是 Edge
  Function `push-dispatch`（見 §10），這裡只記它與這張表的資料面契約。
- 來源：`comments`／`reactions`／`diaries`／`albums`／`media`（LS-175）五張表各自的
  `AFTER INSERT` trigger，只在**新增**時觸發（留言/按讚的收回、日記/相簿/照片的
  編輯或軟刪都不通知）。
- 欄位：`kind`（`comment`/`reaction`/`diary`/`album`/`report`/`media`）＋
  `target_type`／`target_id`（`comment`／`reaction` 指向被留言／被按讚的目標；
  `diary`／`album` 指向內容自己；`media`（LS-175）指向**整個家庭**——
  `target_type='family'`／`target_id=family_id`，理由見下方「`media` 來源
  （LS-175）」）＋`actor_id`（最近一次觸發者）＋`event_count`（彙總筆數）＋
  `occurred_at`（最近一次事件時間）＋`sent_at`（`NULL`＝待送，由 Edge Function／
  `service_role` 標記已送出）。
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
- **`media` 來源（LS-175，`private.notify_media_created()`，
  `20260904170933_media_notification_events.sql`）——`kind='media'`，
  `target_type='family'`／`target_id=family_id`，不是所屬相簿／日記**：這不是
  簡化，是結構性事實——`media` 表沒有 `album_id`／`diary_id` 欄位（一張照片是否
  掛進相簿／日記，是透過 `album_media`／`diary_media` 這兩張連結表**另一次、
  之後才發生**的寫入，見 `LittleSprout/Services/Diary/MediaUploadService.swift`
  的 `insertMediaRow` 與 `SupabaseDiaryAPIClient.attachMedia`——先 insert
  `media` 列的請求跟後續 attach 進 `diary_media` 的請求是兩個分開的 HTTP round
  trip，不是同一個交易）。`album_media`／`diary_media` 的複合外鍵要求 `media`
  列必須先存在，所以 `media` 表自己的 `AFTER INSERT` trigger 在觸發當下，這批
  照片究竟會不會、會掛進哪個相簿／日記，這個資訊在資料庫裡根本還不存在——對
  這兩張連結表做 JOIN 只會查到 0 列，是恆假的死邏輯，這裡不寫。副作用（刻意
  接受）：`kind='album'`（相簿**建立**本身）與 `kind='media'`（**上傳**照片，
  不論最終有沒有掛進相簿）是兩個獨立、不會互相合併的事件——同一個使用者動作
  若是「建立相簿並同時塞照片進去」，會收到兩則通知，不是一則。`event_count`
  累加**張數**（`private.notify_media_created()` 是 statement-level trigger，
  先用 transition table 按 `family_id` 分組再呼叫
  `private.record_notification_event()`，同其餘四張來源表的既有慣例）；只在
  `deleted_at is null` 時計入（軟刪／還原不通知；INSERT 當下 `deleted_at` 就已
  非 NULL 的防禦性邊界也排除在外，見 migration 檔頭）。
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
  檔尾備註）。**LS-172 起，`service_role` 對這張表的既有 `SELECT`／`UPDATE` grant
  在實務上不再被直接使用**——`push-dispatch` 改透過下面兩支 SECURITY DEFINER RPC
  （`claim_notification_events`／`notification_recipients`，皆以 postgres 身分執行，
  不受這張表的 grant 影響）存取，既有 grant 予以保留（無害，不是本票 scope）。
- **`sent_at`（LS-172）**：`NULL`＝待送；由 `public.claim_notification_events()`
  （service_role-only SECURITY DEFINER RPC，見 §4）標記——語意是**先 claim 再送**：
  這支函式在同一句 SQL 內把符合「`sent_at IS NULL` 且視窗已穩定（`occurred_at <
  now() - interval '5 minutes'`）」的列標記 `sent_at = now()` 並回傳，`push-dispatch`
  Edge Function 之後才真的呼叫 APNs。**`sent_at` 被標記即視為已處理，即使後續呼叫
  APNs 失敗，也不會回滾這個標記**——這是刻意的取捨：寧可某一則通知漏送，也不要因為
  重送而讓同一個人對同一件事收到兩次推播（`comments`/`reactions` 等內容本身的重複
  提交已經有各自的冪等機制，但「推播」這個動作沒有——使用者感知到的是「又被通知了
  一次」，沒有天然的去重依據）。若之後要改成「送出失敗才重試」，需要在
  `notification_events` 或另一張表新增獨立的送出結果欄位，不能只看 `sent_at`
  （否則會需要能表達「已 claim 但送出失敗，可重新 claim」這個第三種狀態，目前的
  二元 `NULL`／非 `NULL` 表達不了）——這是已知的、留給未來的擴充點，不在本票範圍。
  併發安全：`claim_notification_events()` 用 `FOR UPDATE SKIP LOCKED`（不是既有
  `record_notification_event()` 那種 `pg_advisory_xact_lock`）——多個幾乎同時的
  claim 呼叫（例如排程重疊）會各自選到不重疊的列，不會有兩個呼叫都 claim 到同一列。

### `content_reports` / `blocked_users`
- `content_reports`：任何家庭成員都能送出檢舉（`reporter_id` 必須是自己）；owner 只能
  把 `status` 改成 `resolved`（無法 `dismissed`——那是平台方的權限，走 `service_role`／
  Dashboard，不在這份 API 契約範圍內）。**LS-149 起建議走 `report_content` RPC**（見
  §4）而不是直接 `.insert()`——直接 INSERT 仍然可用（grant／policy 都沒動），但
  `report_content` 多做了同人同內容去重（同一人對同一內容已有一筆 `pending` 報告時，
  直接回傳既有那筆的 id，不重複新增）與跨家庭目標檢查（`LS026`）。
- `blocked_users`：被封鎖者**看不到**自己被封鎖（policy 只讓 `blocker_id = 我` 的人
  讀寫），UI 不要試圖查「誰封鎖了我」。**LS-149 起建議走 `block_user`／`unblock_user`
  RPC**（見 §4）——直接 `.insert()`／`.delete()` 仍然可用（LS-149 刻意沒有收回既有
  grant／policy，理由見 migration 檔頭「設計裁量」第 3 點），RPC 版本的差異只在冪等
  （`ON CONFLICT DO NOTHING`／對不存在的列 `DELETE` 皆是 no-op，不會撞
  `23505`／噴錯）。
- **封鎖過濾（LS-149）**：被封鎖者的內容在三處查詢一律看不到——`albums_select`／
  `comments_select` 兩條 RLS policy、`get_family_timeline` RPC（時間軸）都疊加了
  `NOT EXISTS`（blocker 對這個 family 的封鎖名單，見 `private.blocked_pairs()`）。
  這是**封鎖者單向的視角過濾**，不是雙向互相看不到——被封鎖的人看得到封鎖者的內容，
  只是反過來看不到（跟 §9-A1 的「封鎖使用者」語意一致：封鎖是「我不想再看到這個人」，
  不是雙向拉黑）。**範圍刻意排除** `media_select`（單張照片／影片的直接讀取）與
  `diaries_select`——時間軸已經把被封鎖者的相簿／日記／照片項目擋住，這兩張表的
  直接讀取路徑不在 LS-149 票文列的三處測項內，是刻意縮小的範圍。

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
- **回傳**：新產生的邀請碼字串（**6 碼**大寫；LS-90，原為 8 碼，見 §3 `invites`
  的「LS-90 變更說明」）。字元集 `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（32 字元，
  拿掉 `0/O/1/I`），6 碼合計 30 bit 熵。
- **參數邊界（RPC 是安全邊界，不是 UI 輔助，直接打 API 的人也會被擋）**：
  - `p_role`：`"owner"|"member"|"viewer"`（cast 失敗 `22P02`）。
  - `p_expires_at`：必須在「現在～現在+30 天」之間，超出 → `LS017`。
  - `p_max_uses`：必須介於 1–20，超出／NULL → `LS017`。
- **錯誤碼**：未登入 `42501`；不是該家 owner `42501`；參數不合法 `LS017`；連續 5 次
  撞碼（機率極低，代表亂數來源異常）`LS016`。
- **併發**：撞碼會自動重抽最多 5 次，對呼叫端透明；重試上限與錯誤碼在 LS-90
  （長度 8→6）時原樣保留，未新增錯誤碼。兩線同時呼叫互不干擾（見
  `supabase/tests/concurrency/invite_create_race_*.sql`）。

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

### `create_diary_entry(p_family_id uuid, p_child_ids uuid[], p_body text, p_entry_date date) -> uuid`
- **BREAKING（LS-121）**：舊簽名 `create_diary_entry(p_family_id uuid, p_child_id
  uuid, p_body text, p_entry_date date)` 已 DROP，不留 overload——第二個參數從
  單一 `uuid` 改成 `uuid[]`，語意也從「單一孩子或不指定」改成「多個孩子或不指定」。
- **誰能呼叫**：該家庭的 owner／member（Viewer 不行，同 `albums`）。
- **回傳**：新日記的 `id`。
- **副作用**：`author_id` 恆為呼叫者本人，不接受由參數指定（防冒名，同 `media.uploaded_by`
  的既有慣例）。
- **參數**：`p_child_ids` 可傳 `NULL` 或空陣列（家庭共用，不掛任何孩子）；非空時
  每個元素都必須是同一家庭的孩子，否則 `23503`（`diary_children` 的複合外鍵）；
  陣列裡的 `NULL` 元素與重複值靜默忽略／去重，不是錯誤（見 §8）。`p_entry_date`
  傳 `NULL` 時退回 `current_date`（對齊資料表原本的欄位預設值，不是「必填」）。
- **錯誤碼**：未登入 `42501`；不是該家 owner/member `42501`；`p_child_ids` 任一
  元素跨家庭 `23503`；`body` 為空或超過 20000 字 `23514`（`CHECK` 約束，非本 RPC
  自訂）；`p_child_ids` 任一元素指向一個已軟刪的孩子 `LS044`（`diary_children`
  的 `BEFORE INSERT` trigger，見 §8）。
- **併發**：無特殊語意，`INSERT INTO diaries` 加上一組 `INSERT INTO diary_children`。

### `update_diary_entry(p_diary_id uuid, p_body text, p_entry_date date, p_child_ids uuid[]) -> void`
- **BREAKING（LS-121）**：舊簽名 `update_diary_entry(p_diary_id uuid, p_body text,
  p_entry_date date, p_child_id uuid)` 已 DROP，不留 overload——第四個參數從
  單一 `uuid` 改成 `uuid[]`，語意也從「整組替換成單一孩子或不指定」改成「整組
  替換成一組孩子或不指定」（見下）。
- **誰能呼叫**：**只有原作者本人，且必須現在仍是該家庭的 owner/member**——即使是該
  家庭的 owner，也不能用這支 RPC 改別人日記的內容（見 §3 `diaries` 段的心智模型
  說明）；作者若已被移出家庭、或被降級成 viewer，同樣不能再編輯自己過去寫的日記
  （merge-reviewer PR #60 review F2：`author_id` 是永遠不變的歷史欄位，不能單獨當
  授權依據）。
- **語意**：**整組替換**（PUT，不是逐欄 PATCH）——`body`／`entry_date` 一律用傳入值
  覆蓋，不支援「傳 `NULL` 代表不變」。呼叫端要送出完整的期望狀態（例如只想改
  `body`，`p_entry_date`／`p_child_ids` 也要照抄原值一起傳）。`p_child_ids` 是
  **全覆蓋**（不是逐一新增／移除）：`NULL` 或空陣列＝清空所有標記；非空＝目前
  的標記集合被替換成這個陣列去重、過濾 `NULL` 元素之後的集合——刪多補少，不在
  新集合裡的既有標記會被刪掉，新集合裡原本沒有的會被補上，值沒變的標記不受影響
  （見 §8）。
- **錯誤碼**：未登入 `42501`；日記不存在 `LS020`；不是作者本人、或雖是作者但已不是
  該家庭 owner/member `LS021`（兩種情況共用同一個碼，**排在「是否已軟刪除」之前
  檢查**——未通過授權的人，不管日記是否已被移除，一律拿到 `LS021`，不會從錯誤碼差異
  推敲出一篇不屬於自己的日記目前是否已被軟刪除，同 `approve_join` 的授權檢查排序
  慣例）；已軟刪除（`deleted_at` 非 NULL）`LS020`（要先用 `set_diary_deleted(id,
  false)` 還原才能編輯）；`p_child_ids` 任一元素跨家庭 `23503`；任一元素指向一個
  已軟刪的孩子 `LS044`（`diary_children` 的 `BEFORE INSERT` trigger——只在真的要
  新增一列標記時才會觸發到，值沒變的既有標記不受影響，見 §8 的裁量說明）。
- **併發**：對目標日記列用 `FOR UPDATE` 鎖住，`body`／`entry_date` 的 `UPDATE` 與
  `diary_children` 的「刪多補少」都在同一個交易、同一把鎖之後執行——兩個連線同時對
  同一篇日記呼叫、各自想要不同的孩子集合，後動的那個會被這把鎖擋住直到先動的
  commit，終態是「後 commit 那次呼叫的完整集合」，不會是兩次呼叫的合併（見
  `supabase/tests/concurrency/diary_children_race_*.sql`）。與 `set_diary_deleted`
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
  （物理上不會執行到 `body`／`entry_date` 的 `UPDATE`，也不會碰 `diary_children`）。
- **副作用**：軟刪後該篇立即從 `feed_items`／`get_family_timeline` 消失，還原後立即
  回來（既有 trigger 行為，見 `supabase/tests/40_triggers_feed_and_storage.sql`）。
  **`deleted_by` 記錄與還原鎖（LS-57，PR #98 review B1/B2/B3 修過）**：軟刪時
  `deleted_by` 由 `private.enforce_deletion_attribution()` trigger 自動寫成呼叫者
  本人，呼叫端無法指定；還原或重新軟刪時，**作者只能觸碰 `deleted_by` 是自己的
  那一篇**——若這篇日記是 owner 軟刪的，作者呼叫 `set_diary_deleted`（不論
  `p_deleted` 是 `true` 還是 `false`）都會拿到 `LS027`，即使他通過了上面「仍是該
  家庭成員」的授權檢查也一樣（這是還原方向多一層的檢查，不是取代上面那層）；
  **owner 可以還原任何一篇、也可以對已被作者自刪的日記再次移除——後者會把
  `deleted_by` 升級成 owner 自己（不是維持作者不變），owner 的動作永遠壓過作者
  的自刪**。`deleted_by` 為 `NULL` 有兩種成因：本欄位新增之前就已軟刪除的既有
  資料，或移除者的帳號後來被刪除（`references profiles(id) on delete set null`，
  這支 trigger 會放行帳號刪除觸發的 RI 動作本身，不會讓帳號刪不掉）——兩種情況
  都視為「移除者不明」，**一律只有 owner 能還原，不是任何人都能還原**。
- **錯誤碼**：未登入 `42501`；日記不存在 `LS020`；不是作者也不是該家 owner，或雖是
  作者但已離開家庭 `42501`；作者想還原或重新軟刪 owner 移除的日記（含 `deleted_by`
  為 `NULL` 的情況）`LS027`（LS-57）。
- **併發**：對目標列用 `FOR UPDATE` 鎖住；與 `update_diary_entry` 的互斥關係見上。
  **這把鎖對「owner 軟刪 vs 作者還原」這個 race 不是必要條件**（merge-reviewer
  PR #98 review B4，實測拿掉這把鎖重跑
  `supabase/tests/concurrency/diary_delete_vs_restore_*.sql` 仍然全綠）——這個 race
  真正被擋下靠的是 `diaries` 表本身的 `enforce_deletion_attribution()` BEFORE
  UPDATE trigger：Postgres 對有 BEFORE ROW UPDATE trigger 的表，任何一句 UPDATE
  本身就會在觸發 trigger 前鎖住目標列、解鎖後用 EvalPlanQual 重取最新版本，不需要
  呼叫端額外帶 `FOR UPDATE`。這把鎖真正必要的地方是保護 `update_diary_entry` 自己
  「是否已軟刪除」的檢查不用到過期快照（見上一支 RPC 的併發說明），不是這裡。

### `set_album_deleted(p_album_id uuid, p_deleted boolean) -> void`
- **誰能呼叫**：建立者本人（**只要求仍是該家庭任一角色的成員**，orchestrator PR
  #70 review F5 裁決對齊 `set_diary_deleted`／`set_comment_deleted`——被降級成
  viewer 仍可移除／還原自己建立的相簿）**或**該家庭的 owner（家庭內任何一本
  相簿）。**這個要求比 `albums_update` policy 的建立者分支寬**（那支要求仍是
  owner/member，見 §3）——「改內容」與「移除／還原自己的東西」是不同性質的
  操作，前者是持續的創作權，後者更接近對自己貢獻過的東西最基本的處置權，兩者
  刻意不同高標準，不是本票的不一致，理由見 migration 對這支函式的裁量說明。
- **用途**：軟刪（`p_deleted = true`）／還原（`p_deleted = false`）。**LS-57 R2
  起是唯一能寫 `deleted_at` 的路徑**——建立者與 owner 皆同，直接 `.update()` 這欄
  一律 `42501`（欄位級 grant 收回，見 §2/§3）。這支 RPC 只碰 `deleted_at`／
  `deleted_by` 兩欄，物理上不可能被拿來竄改 `title`／`cover_media_id`（不會執行
  到那些欄位的 `UPDATE`），也不會碰 `album_children`。R1 版本建立者原本還能改用直接 `.update()`
  軟刪／還原自己的相簿（兩條路徑並存），R2 起這條路徑已經不存在（見 §3），這支
  RPC 是建立者與 owner 共同的唯一路徑；被降級成 viewer 的建立者仍可呼叫（只要求
  仍是該家庭任一角色的成員，不要求仍是 contributor，見上）。
- **`deleted_by` 記錄與還原鎖**：`deleted_by` 由
  `private.enforce_deletion_attribution()` trigger 統一推導寫入，**無法透過
  `UPDATE`（不論是這支 RPC 內部還是直接 `.update()`）指定**——R2 起這欄同樣無
  UPDATE 欄位級 grant。**`INSERT` 方向不受這個保證涵蓋**（merge-reviewer PR #98
  review R3 F4）：`albums` 對 `authenticated` 仍是整表 INSERT grant，建立者
  `insert into albums (…, deleted_by) values (…)` 技術上會成功，但
  `albums_insert` 的 WITH CHECK 只允許 `created_by = auth.uid()` 且屬於自己
  contributor 的家庭——新建的這一列本來就是他自己的，塞一個任意 `deleted_by`
  值不構成越權（頂多是自己騙自己「這篇被 owner 移除過」），不是需要另開
  `BEFORE INSERT` 分支或收 INSERT 欄位級 grant 去堵的洞（YAGNI）。建立者
  只能觸碰 `deleted_by` 是自己的那一本；owner 軟刪的相簿，建立者呼叫這支 RPC
  一律拿到 `LS027`；**owner 可以還原任何一本，也可以對已被建立者自刪的相簿再次
  移除——後者會把 `deleted_by` 升級成 owner 自己，owner 的動作永遠壓過建立者的
  自刪**。`deleted_by` 為 `NULL`（本欄位新增之前就已軟刪除的既有資料，或移除者
  帳號後來被刪除）一律視為「移除者不明」，只有 owner 能還原。
  **`family_id` 不可變**：R2 起這欄同樣無 UPDATE 欄位級 grant，直接
  `.update({family_id: …})` 一律 `42501`（見 §3「albums / diaries」）；trigger
  仍保留同一條檢查作為繞過 grant 的路徑（SECURITY DEFINER RPC、表擁有者身分）的
  第二道防線，這支 RPC 本身從不寫 `family_id`，不受影響。
- **錯誤碼**：未登入 `42501`；相簿不存在 `LS023`；不是建立者也不是該家 owner，或
  雖是建立者但已完全離開該家庭 `42501`；建立者想還原或重新軟刪 owner 移除的相簿
  （含 `deleted_by` 為 `NULL` 的情況）`LS027`（LS-57）。
- **併發**：對目標列用 `FOR UPDATE` 鎖住。**這把鎖對「owner 軟刪 vs 建立者還原」
  這個 race 不是必要條件**（merge-reviewer PR #98 review B4，實測拿掉這把鎖重跑
  `diary_delete_vs_restore_*.sql` 這組場景仍然全綠——albums／comments 走同一支
  共用 trigger，機制相同，不重複另立一組相簿專屬的併發測試；理由見
  `set_diary_deleted` 的併發說明）：這個 race 真正被擋下靠的是 `albums` 表本身的
  `enforce_deletion_attribution()` BEFORE UPDATE trigger 的內建列鎖，不是這支 RPC
  的 `FOR UPDATE`；這把鎖仍然保留，作為授權讀取（讀 `family_id`／`created_by`
  做授權判斷）的 TOCTOU 防線，見
  `supabase/tests/concurrency/diary_delete_vs_restore_s2_author_restore.sql` 檔頭
  R2 追記。
  **`family_id` 搬家 race 已隨 LS-57 退役（R2 起以欄位級 grant 為根本理由，不只是
  trigger 順序）**：這把鎖原本還額外防著「建立者把相簿直接 `.update()` 搬到別的
  家庭、同時原家庭 owner 呼叫這支 RPC 軟刪」的跨家庭越權 race——`family_id` 現在
  對 `authenticated` 無 UPDATE 欄位級 grant（R2 N1/N2 根治，不只是 R1 那支
  trigger 檢查），建立者的搬家 UPDATE 本身在 grant 層就會被 `42501` 擋下，不論
  單句還是多句、不論是否夾帶其他欄位，這個攻擊面在前提上已經不成立，不需要再靠
  鎖或併發時序去驗（R2 review N3 一度指出 R1 的 trigger 順序漏洞讓這個退役理由
  站不住腳，欄位級 grant 修好之後這個退役理由重新成立，且比 R1 當時更徹底）。
  `album_edit_vs_delete_s1_move_family.sql`／`s2_delete_after_move.sql`／
  `verify_move_blocked.sql` 這組回歸測試因此隨本票一起退役，改用
  `supabase/tests/88_deletion_attribution.sql` §2／§2b／§2c 的欄位級 grant 斷言
  與 reviewer 原始 X0-X3／Y0-Y2 情境作替代覆蓋（比照 LS-58 讓 comments
  版同一場景退役的處理方式，見 `supabase/tests/run.sh` 對應段落）。`FOR UPDATE`
  鎖本身仍是保守保留（不是本票要清理的既有技術債，migration 也是歷史紀錄不回頭
  改），繼續為一般序列化把關，回歸測試見 `album_edit_vs_delete_s1_update.sql`／
  `s1_delete.sql` 兩組（作者改 `title`、owner 軟刪同時發生）。

### `set_album_children(p_album_id uuid, p_child_ids uuid[]) -> void`（LS-121，新增）
- **誰能呼叫**：**建立者本人，且必須現在仍是該家庭的 owner/member**——跟內容欄位
  （title／cover_media_id）的直接 `.update()` 授權門檻一致（見 §3 `albums` 段），
  不是 `set_album_deleted` 那種「owner 也能對別人的相簿做」的移除／還原權限：
  標記孩子屬於「內容」，不是「移除」。
- **用途**：設定一本相簿的寶貝標記，唯一能寫 `album_children` 的路徑（直接
  `.insert()`/`.delete()` 對 `authenticated` 一律 `42501`，見 §3）。
- **語意**：**全覆蓋**（PUT，不是逐一新增／移除）——`p_child_ids` 為 `NULL` 或
  空陣列＝清空所有標記；非空＝目前的標記集合被替換成這個陣列去重、過濾 `NULL`
  元素之後的集合，刪多補少（同 `update_diary_entry` 的 `p_child_ids` 語意，見
  §4 該支與 §8）。**刻意不檢查相簿是否已軟刪除**（跟 `update_diary_entry` 不同，
  那支明確拒絕編輯已軟刪除的日記）——已軟刪除的相簿仍可改標記，理由同
  `update_comment`（見 §3「comments」段）：這是「內容編輯」這一支動作既有的既定
  行為（`albums_update` 的建立者分支現在也還是沒有這條限制），不是通用規則，
  comments／albums 沒有理由被動繼承 diaries 自己的產品決定。
- **`deleted_at`／還原期間的行為（LS-121 R2）**：軟刪期間改標記，`album_children`
  照樣落地，但 `feed_item_children`（`get_family_timeline` 篩 child 用的查詢引擎，
  見 §8）在軟刪期間維持 0 列（該相簿本來就不在 `feed_items` 裡，見 §3
  `albums`/`diaries` 段）；還原後 `feed_item_children` 會依 `album_children` 當下
  （軟刪期間可能已經改過）的集合重新展開，不是還原成軟刪前的舊集合。
- **錯誤碼**：未登入 `42501`；相簿不存在 `LS023`（跟 `set_album_deleted` 共用同一
  個碼，語意一致：「相簿不存在」）；不是建立者本人、或雖是建立者但已不是該家庭
  owner/member `LS045`（LS-121 新碼）；`p_child_ids` 任一元素跨家庭 `23503`；
  任一元素指向一個已軟刪的孩子 `LS044`（`album_children` 的 `BEFORE INSERT`
  trigger，見 §8）。
- **併發**：對目標相簿列用 `FOR UPDATE` 鎖住，`album_children` 的「刪多補少」在
  同一個交易、同一把鎖之後執行——理由與併發保證同 `update_diary_entry`（見上）。

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
- **`deleted_by` 記錄與還原鎖（LS-57，PR #98 review B1/B2/B3 修過）**：軟刪時
  `deleted_by` 由 `private.enforce_deletion_attribution()` trigger 自動寫成呼叫者
  本人，呼叫端無法指定；作者只能觸碰 `deleted_by` 是自己的那一則——owner 軟刪的
  留言，作者呼叫 `set_comment_deleted`（不論 `p_deleted` 是 `true` 還是 `false`）
  都會拿到 `LS027`；**owner 可以還原任何一則，也可以對已被作者自刪的留言再次
  移除——後者會把 `deleted_by` 升級成 owner 自己，owner 的動作永遠壓過作者的
  自刪**。`deleted_by` 為 `NULL`（本欄位新增之前就已軟刪除的既有資料，或移除者
  帳號後來被刪除）一律視為「移除者不明」，只有 owner 能還原。
- **錯誤碼**：未登入 `42501`；留言不存在 `LS024`；不是作者也不是該家 owner，或
  雖是作者但已離開家庭 `42501`；作者想還原或重新軟刪 owner 移除的留言（含
  `deleted_by` 為 `NULL` 的情況）`LS027`（LS-57）。
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

### `get_family_timeline(p_family_id uuid, p_child_id uuid default null, p_cursor_occurred_at timestamptz default null, p_cursor_ref_id uuid default null, p_limit integer default 20) -> table(kind public.feed_kind, ref_id uuid, occurred_at timestamptz, child_ids uuid[])`
- **BREAKING（LS-121）**：回傳欄從 `child_id uuid` 改成 `child_ids uuid[]`——參數
  簽章沒變（還是同一組 5 個參數），但回傳形狀對呼叫端是真實的破壞性變更。舊呼叫端
  若解析 `child_id`（單一 uuid）會直接壞掉，必須改讀 `child_ids`（陣列）。
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
- **`p_child_id`**：`NULL`＝不篩（回傳全部，含沒有任何孩子標記的項目與所有
  `media`），查詢路徑走 `feed_items` 本身；帶值＝只回傳標記含這個孩子的項目，
  查詢路徑改走 `feed_item_children`（見 §8 的設計取捨）。**`media` 類項目在指定
  `p_child_id` 時恆不出現**（見 §3 `feed_items` 段的裁量說明），這不是 bug。
- **回傳的 `child_ids`**：該項目標記的**全部**孩子（不只是 `p_child_id` 篩選命中的
  那一個）——一篇日記同時標了 2 個孩子時，不論用哪一個孩子篩選，回傳列的
  `child_ids` 都是那 2 個孩子的完整陣列，呼叫端可以直接拿去畫全部的寶貝徽章，
  不需要另外查一次。沒有任何標記時是空陣列 `{}`，不是 `NULL`（`media` 類恆此）。
- **分頁**：keyset，游標是 `(p_cursor_occurred_at, p_cursor_ref_id)` 這一對——傳上一頁
  最後一列的 `occurred_at`／`ref_id`。第一頁兩者都不傳（或都傳 `NULL`）。**只傳其中
  一個（另一個留 `NULL`）會拿到 `LS022`**——半游標不是合法用法，呼叫端要嘛都傳、要嘛
  都不傳；這支 RPC 不會為了容錯半游標而靜默回傳空集合（那會讓呼叫端誤判成「這頁真的
  沒資料了」）。**篩 child 的分頁一樣不會跳項或重複**——`feed_item_children` 對
  每個 `(kind, ref_id)` 依標記的孩子各自有一列，keyset 排序鍵與 `feed_items` 同一套
  `(occurred_at desc, ref_id desc)`，游標語意完全一致（見
  `supabase/tests/97_multi_child_tags.sql`）。
- **`p_limit`**：下界會被夾到 1（傳 `0` 或負數不會被誤用成「不限筆數」）、上界夾到
  100；預設 20。兩端都有測試覆蓋（`supabase/tests/85_diaries_timeline.sql`，上界測試
  用了一個 >100 筆的家庭資料集，不是只驗小數字下「反正沒差」的空案例）。
- **錯誤碼**：未登入時 `auth.uid()` 為 `NULL`，配合 RLS 自然回傳 0 列，不 raise；
  游標只傳一半 `LS022`。
- **併發**：無寫入，讀取穩定（`stable`），不會有寫入衝突。
- **效能**：`language plpgsql`，依 `p_child_id`／游標是否為 `NULL` 拆成四條各自可以
  走索引的靜態查詢（不是同一句 SQL 裡的 `OR` 分支）——這是刻意的實作選擇，不只是
  風格：`language sql` 搭配 `set search_path` 會讓函式無法被規劃器 inline，`OR` 條件
  就下推不進 index cond。不篩 child 的兩條分支走 `feed_items` 本身既有的索引；篩
  child 的兩條分支改走 `feed_item_children_family_child_occurred_idx`（見 §8）。
  每條分支各自在子查詢裡先完成「篩選＋排序＋LIMIT」，才對這一頁（≤`p_limit`
  列）逐列查一次 `child_ids`（`diary_children`／`album_children` 依 `kind` 分流的
  correlated 子查詢，走各自 PK 的索引）——跟 `list_comments` 「先子查詢篩選排序
  LIMIT，才 LEFT JOIN 拿額外欄位」是同一種時機（見該支 RPC 說明），不會在篩選＋
  排序之前對任一張連結表做 join。細節與 EXPLAIN 證據見 migration 內
  `public.get_family_timeline` 的完整說明與
  `supabase/tests/50_rls_plan_no_percall_subquery.sql` 的專屬效能回歸段落。

### `create_child(p_family_id uuid, p_name text, p_birthday date, p_avatar_url text) -> uuid`
- **誰能呼叫**：該家庭的 owner／member（LS-47 定案第②題：新增／編輯 owner＋member
  皆可）。Viewer 不行。
- **用途**：建立孩子檔案。不接受呼叫端指定 `id`／`deleted_at`，只有這四個欄位。
- **錯誤碼**：未登入 `42501`；不是該家庭 owner/member `42501`；`p_name` 不合法
  （空字串或超過 50 字）`23514`；`p_birthday` 為 `NULL` `23502`（R1 I6：這兩個是
  表本身既有的 `CHECK`/`NOT NULL` 約束，不是本票新開的自訂碼，見 §3／§5 標準碼表）。
- **併發**：純 INSERT，無鎖需求。

### `update_child(p_child_id uuid, p_name text, p_birthday date, p_avatar_url text) -> void`
- **誰能呼叫**：仍是該家庭 owner／member 的成員（動態檢查，不是「建立者」——`children`
  沒有建立者欄位，任何仍是 owner/member 的人都能編任何一個孩子的檔案）。已被降級成
  viewer 就不能再編輯，即使他當初建立了這個孩子檔案。
- **用途**：PUT 語意整組替換 `name`／`birthday`／`avatar_url`（不是逐欄 PATCH）。
  已被軟刪除的孩子檔案不能編輯——要嘛先用 `set_child_deleted` 還原，要嘛就是被移除
  了，兩種情況都不該讓內容在那個狀態下被改動（理由同 `update_diary_entry`）。
- **錯誤碼**：未登入 `42501`；孩子檔案不存在或已被軟刪除須先還原 `LS041`；不是仍是
  該家庭 owner/member 的成員 `LS042`；`p_name`/`p_birthday` 不合法同 `create_child`
  的 `23514`/`23502`（R1 I6）。
- **併發**：對目標列用 `FOR UPDATE` 鎖住，與 `set_child_deleted` 之間序列化（回歸測試
  見 `supabase/tests/concurrency/children_edit_vs_delete_*.sql`）。

### `set_child_deleted(p_child_id uuid, p_deleted boolean) -> void`
- **誰能呼叫**：**僅該家庭 owner**——比 `create_child`／`update_child` 窄，也比
  `set_album_deleted`／`set_comment_deleted`（建立者本人或 owner）窄：`children`
  沒有建立者欄位，且刪除孩子檔案是比刪一篇日記／一本相簿重得多的破壞性動作，門檻
  對齊 §10「Owner 移除內容」，不下放給 member（LS-47 定案第②題：「刪除僅 owner」）。
- **用途**：軟刪（`p_deleted = true`）／還原（`p_deleted = false`），寫
  `deleted_at`／`deleted_by`。**還原有 30 天邊界**：`deleted_at` 已超過 30 天前時，
  `p_deleted = false` 會被拒絕（`LS043`），不執行還原；30 天後的清除／保留策略是
  排程票的範圍，這支 RPC 只負責這個邊界判斷本身。**重複軟刪是 no-op**（R1，
  merge-reviewer PR #95 review I1/I2）：對已經是軟刪狀態的孩子再次呼叫 `true`，
  `deleted_at`／`deleted_by` 完全不變——不會刷新時間戳（否則 owner 可以無限延後
  30 天邊界），也不會把歸屬洗成這次呼叫者（語意對齊 LS-57 對 diaries/albums/comments
  `deleted_by` 的推導規則）。只有「從 active 到已軟刪」這一次真正的狀態轉換才寫入
  新的 `deleted_at`/`deleted_by`；還原之後再重新軟刪，因為那時已經回到 active，
  會被視為全新一次刪除、重新計時、重新歸屬。對本來就是 active 的孩子呼叫 `false`
  仍是 no-op。**照片／日記不連動**：這支 RPC 只碰 `children` 一張表的
  `deleted_at`／`deleted_by` 兩欄，`diary_children`／`album_children` 裡掛在這個
  孩子底下的既有標記完全不受影響，見 §8；但**已軟刪的孩子不能再被指定為新內容的
  標記**——`create_diary_entry`／`update_diary_entry`／`set_album_children` 若把
  `p_child_ids` 任一元素指向一個已軟刪的孩子，一律拿 `LS044`（R1 I3；LS-121 起
  守門搬到連結表的 `BEFORE INSERT` trigger，見 §8）。
- **錯誤碼**：未登入 `42501`；孩子檔案不存在 `LS041`；不是該家庭 owner `42501`；
  還原但已超過 30 天 `LS043`。
- **併發**：對目標列用 `FOR UPDATE` 鎖住——這是讀 `family_id`／`deleted_at` 做授權與
  30 天邊界判斷的 TOCTOU 防線（LS-52 定下的規則：任何 RPC 授權判斷讀到的列都要先
  鎖住），純防禦性作法。**R1 訂正**（merge-reviewer PR #95 review M1）：這裡原本
  宣稱「回歸測試同 `update_child` 條目」，但四種 mutation 實測後發現不成立——拿掉
  這句 `for update`，`supabase/tests/concurrency/children_edit_vs_delete_*.sql` 兩個
  方向的併發測試都還是綠的（`family_id` 有 immutable trigger 擋著搬家，這裡也沒有
  建構出讓這把鎖單獨扮演關鍵角色的情境），沒有任何測試實際覆蓋這句鎖被拿掉的後果；
  `update_child` 開頭那句 `for update` 才是真正有回歸覆蓋的（見該條目），兩者不是
  同一件事。

### `list_children(p_family_id uuid) -> table(id uuid, name text, birthday date, avatar_url text, deleted_at timestamptz, created_at timestamptz)`
- **誰能呼叫**：任何已登入使用者，但只查得到自己所屬家庭的資料——`p_family_id` 傳一個
  自己不屬於的家庭不會報錯，只會回傳 0 列（`security invoker`，完全依賴 `children`
  既有的 `children_select` RLS policy，見 §3）。
- **用途**：列出一個家庭的孩子檔案，依 `birthday` 排序。**回傳全部列，不分角色、不分
  軟刪與否**（R1 I3/I4）——owner／member／viewer 呼叫都會看到 active＋已軟刪的孩子，
  `deleted_at`／`deleted_by` 對所有人都是可見的唯讀旗標；**只有「還原」這個動作**
  （`set_child_deleted(p_deleted=false)`）限 owner，讀取本身不分角色。呼叫端要區分
  「篩選清單只列 active」與「owner 的管理畫面含已軟刪」，用同一支 RPC、依
  `deleted_at` 是否為 NULL 自行分流即可，不需要兩支不同的 RPC——也不需要為了「一般
  成員不該看到已軟刪的孩子」這件事做任何額外過濾：這是刻意的設計，不是漏洞，理由
  是呼叫端本來就可能從 `get_family_timeline` 拿到一個已軟刪孩子的 `child_id`（§8
  的「軟刪不連動」），任何角色都必須能用 `list_children` 把這個 `child_id` 解析回
  名字，否則會出現「時間軸上有一則內容屬於某個孩子，但這個孩子的名字對這個角色來說
  查無此人」的斷裂體驗。
- **錯誤碼**：無自訂碼；未登入時 `auth.uid()` 為 `NULL`，配合 RLS 自然回傳 0 列。
- **併發**：無寫入，讀取穩定（`stable`），不會有寫入衝突。

### `report_content(p_family_id uuid, p_target_type text, p_target_id uuid, p_reason text) -> uuid`
- **LS-149**（PLAN §9-A1 UGC 三件套）。任何家庭成員都能檢舉同家庭的內容
  （`album`／`media`／`diary`／`comment`，同 `content_target_type`）。
- **參數簽章刻意跟 `create_comment`／`toggle_reaction` 同型**（`p_family_id` 由呼叫端
  傳，不是伺服器端從 target 反查）——這是為了沿用既有的 `LS026`（target 存在但屬於
  別的家庭）與 `private.target_family_id()` 既有判斷，不必為了「不接受呼叫端指定
  family」這個更嚴謹但更少見的設計新開一個錯誤碼（本票不能碰 iOS 端的
  `LSErrorCode`，新碼會讓 `scripts/gates/error-codes-check.sh` 三方對帳直接紅）。
  孤兒 `target_id`（查不到）維持既有裁量放行，同 `create_comment`。
- **去重**：同一人對同一內容若已有一筆 `status='pending'` 的報告
  （partial unique index `content_reports_reporter_target_pending_key` on
  `(target_type, target_id, reporter_id) where status = 'pending'`），直接回傳既有那筆
  的 `id`，不重複新增、不報錯。先前的報告若已經 `resolved`，同一人可以再檢舉一次
  （代表內容已被處理過一輪，之後又有新狀況）。
- **錯誤碼**：未登入 `42501`；不是該家庭成員 `42501`；target 存在但屬於別的家庭
  `LS026`。
- **併發**：`INSERT ... ON CONFLICT ... DO NOTHING` 本身是原子操作，不需要額外的鎖。

### `block_user(p_family_id uuid, p_blocked_id uuid) -> void` / `unblock_user(p_family_id uuid, p_blocked_id uuid) -> void`
- **LS-149**。封鎖／解除封鎖僅限同一家庭內——`blocked_users` 主鍵含 `family_id`，
  封鎖是「這個人在這個家庭底下的內容我不想看到」，不是跨家庭的全域拉黑。呼叫者必須
  是 `p_family_id` 的成員；`p_blocked_id` 不驗證是否為該家庭成員（既有的
  `blocked_users_not_self` `CHECK` 約束擋自我封鎖，`23514`）。
- **這兩支是既有直接 `.insert()`／`.delete()` 路徑之外的額外入口，不是收斂**——
  `blocked_users` 的 grant／policy 沒有被收回（見 §2／§3），差異只在冪等：
  `block_user` 用 `ON CONFLICT DO NOTHING`（重複封鎖同一人不會撞 `23505`）；
  `unblock_user` 對不存在的封鎖關係是單純的 0 列 `DELETE`（no-op，不報錯）。
- **錯誤碼**：未登入 `42501`；`block_user` 額外要求呼叫者是該家庭成員 `42501`；
  自我封鎖 `23514`（`blocked_users_not_self`）。
- **併發**：兩支都是單一敘述的原子操作，不需要額外的鎖。
- **封鎖生效範圍**：見 §3 `content_reports` / `blocked_users` 段——時間軸
  （`get_family_timeline`）、留言（`list_comments`／`comments_select`）、相簿
  （`albums_select`）三處查詢立即套用，不需要額外呼叫任何「重新整理」的 RPC。

### `remove_content_as_owner(p_target_type text, p_target_id uuid) -> void`
- **LS-149**（PLAN §10-B）。**純 owner 專用**——跟 `set_album_deleted`／
  `set_diary_deleted`／`set_comment_deleted` 允許「owner 或內容作者本人」不同，這支
  只認 owner（名字就叫 `_as_owner`），內容作者想移除自己的內容仍用那三支既有 RPC。
- **內部直接呼叫既有三支軟刪 RPC**（`album`→`set_album_deleted`、
  `diary`→`set_diary_deleted`、`comment`→`set_comment_deleted`），不重寫軟刪邏輯，
  `deleted_by` 由那三支既有的 `private.enforce_deletion_attribution()` trigger 照舊
  推導（呼叫者已被驗證是 owner，落在那三支既有函式的 owner 分支）。`media` 沒有對應
  的軟刪 RPC（既有的 `media` 軟刪本來就是直接 `UPDATE deleted_at` 的欄位級 grant，見
  §3 `media` 段），這裡直接對 `media` 做同一種 `UPDATE`——**已知不對稱**：`media` 沒有
  `deleted_by` 欄位可以記錄移除者（既有 schema 的既有缺口，不在本票範圍內補）。
- **移除成功後**，這則內容全部 `status='pending'` 的檢舉一併標記 `resolved`。
- **錯誤碼**：未登入 `42501`；找不到內容或不是它所屬家庭的 owner，統一回 `42501`
  （不區分「不存在」與「不是 owner」，同 `LS015`／`LS020` 既有的語意合併慣例，見上方
  §5）；`album`／`diary`／`comment` 三種 dispatch 到既有 RPC 之後，理論上不會再拿到
  那三支各自的「not found」碼（呼叫前已經驗證過 target 存在），除非發生極端的併發
  刪除競態，此時沿用那三支既有的錯誤碼語意（`LS020`／`LS023`／`LS024`）。
- **併發**：依賴內部呼叫的三支既有 RPC 各自的 `FOR UPDATE` 鎖；`media` 分支是單一
  `UPDATE` 敘述，本身原子。

### `get_family_quota(p_family_id uuid) -> table(storage_used_bytes bigint, storage_quota_bytes bigint)`
- **LS-149**（PLAN §10-A）。供 UI 顯示儲存額度用量條。**誰能呼叫**：任何已登入使用者，
  但只查得到自己所屬家庭的資料——`p_family_id` 傳一個自己不屬於的家庭不會報錯，只會
  回傳 0 列（`security invoker`，完全依賴 `families` 既有的 `families_select` RLS
  policy，同 `get_family_timeline`／`list_children` 的既有慣例）。這兩個欄位本來就能
  透過 `.from("families").select("storage_used_bytes,storage_quota_bytes")` 直接讀到
  （SELECT 沒有欄位級限制，只有 UPDATE 有，見 §2），這支 RPC 純粹是給 UI 一個更直接
  的入口，不是新開一條授權路徑。
- **錯誤碼**：無自訂碼；未登入時 `auth.uid()` 為 `NULL`，配合 RLS 自然回傳 0 列。
- **併發**：無寫入，讀取穩定（`stable`），不會有寫入衝突。

### `delete_my_account() -> void`（LS-143；media 軟刪見 LS-155；停權豁免見 LS-179）
- **誰能呼叫**：**任何已登入使用者，包含被停權的使用者、以及被停權家庭裡的成員**
  （LS-179 R2，App Store Guideline 5.1.1(v)／PLAN §9-A2：app 內帳號刪除是硬規定，
  不能因為帳號或所屬家庭被停權就失效——這正是被停權的人最可能需要的出路）。
  無參數。函式內部第一步呼叫 `private.enforce_deletion_bypass()`，設一個交易級
  （`is_local=true`）GUC 讓下面所有寫入略過停權檢查；`pg_catalog.set_config`
  不在 PostgREST 曝露的 schema（`supabase/config.toml` 的
  `[api] schemas = ["public", "graphql_public"]`）裡，client 沒有任何路徑能自己
  設這個值，且它的作用範圍就是這一次呼叫的交易本身，見
  `private.deletion_bypass_active()` 的函式註解與
  `supabase/tests/105_suspension_and_registrations.sql` 場景 10／11（n1 訂正：
  場景 8 是 `suspension_notes`、場景 9 是 `content_reports`，跟 `delete_my_
  account()` 無關）。
- **用途**：app 內刪除帳號的**資料面**入口（PLAN §9-A2／App Store Guideline
  5.1.1(v)）。逐一檢查呼叫者所屬的每個家庭，依角色分三種結果：
  1. **是某家庭的唯一 owner、且該家庭還有其他成員** → 整個呼叫被拒絕，`LS050`，
     **不執行任何寫入**（不會只處理一部分家庭）。錯誤的 `DETAIL` 欄位帶一個 JSON
     陣列，列出**全部**需要先轉移 owner 身份的家庭：
     `[{"family_id": "...", "family_name": "..."}, ...]`（依 `family_name` 排序）。
     轉移本身走既有路徑——owner 對 `family_members.role` 的直接 `UPDATE`（見 §3
     `family_members`），本 RPC 不提供另一支轉移用的 RPC。使用者轉移完所有列出的
     家庭之後，重新呼叫本 RPC 即可繼續。
  2. **是某家庭的唯一成員**（因此也必然是唯一 owner——不可能同時符合情況 1 的
     條件）→ **整個家庭連同底下資料一併刪除**（`DELETE FROM families`
     cascade：`albums`／`diaries`／`media`／`album_media`／`diary_media`／
     `comments`／`reactions`／`invites`／`join_requests`／`content_reports`／
     `blocked_users`／`feed_items`／`family_members` 全部隨之消失）。**Storage
     清理契約**：本 RPC 只清 DB 端的 `media` 列，`media` bucket 裡對應的實體檔案
     不會被同步刪除——依 §5「離線對帳」既有定義，這些檔案在 `media` 列消失之後
     即成為孤兒物件；批次清除是另一張票（不在本 RPC 範圍），可用
     `storage.objects` 的 `name` 前綴（家庭已刪除，前綴即該 `family_id`）批次
     鎖定要清的物件，不需要重跑一般孤兒物件的全表比對。
  3. **其餘家庭**（可能是有共同 owner 的 owner／member／viewer）→ 自己的
     `diaries`／`albums`／`comments` 依既有 soft delete 策略處理
     （`deleted_at = now()`、`deleted_by = 自己`，語意等同作者自己呼叫
     `set_diary_deleted`／`set_album_deleted`／`set_comment_deleted` 自刪），然後
     離開家庭（`DELETE family_members`）——**家庭本身與其他成員的內容完全不受
     影響**。**`media`（LS-155，R2 訂正範圍）**：呼叫者上傳的每一張仍存在的
     照片／影片一併 `deleted_at = now()`——**不限定「呼叫者目前是不是這個家庭的
     成員」**，含相簿內與日記附帶的，也含呼叫者已經退出／被移除、但那個家庭裡
     還留著他上傳的 media 這種情況（`family_members_delete` policy 允許自行
     退出／被 owner 移除，退出時 media 不會被清掉，是既有的正常狀態，見 §3
     `family_members`）——使用者裁決是「該使用者上傳的照片全部刪」，不是「仍在
     的家庭才刪」。做法是逐家庭處理（直接從 `media` 表反查涉及的家庭集合，
     `family_id` 遞增序，見下方「併發」段落與 migration 檔頭「R2」的完整推演）；
     `diary_media`／`album_media` 連結列不動，靠 `media.deleted_at` 軟刪隱藏——
     **R2 起這在伺服器端真的生效**：`media_select` RLS policy 加了
     `deleted_at is null`（上傳者自己例外，`20260904080921_media_select_hide_deleted.sql`），
     被軟刪的 media 對**其他**家庭成員立即消失，不只是「連結列還在但沒人會
     看」（R1 版本這句話原本不成立，`media_select` 當時完全沒有過濾
     `deleted_at`，merge-review R1 M2 實測日記附帶／相簿封面仍會顯示，見下方
     §「Storage」／§6，該處也記錄了上傳者例外為什麼是必要的，不是可省的細節）。
     情況 2 的家庭這時已經因為 cascade 被硬刪，這裡對那些
     列自然找不到，不會重複處理。**額度立即釋放**：既有的
     `private.media_storage_sync()` trigger（§3 `media`／§10-A，`LS002` 額度
     硬防線的同一支 trigger）偵測到 `deleted_at` 從 `NULL` 變成非 `NULL` 就會
     自動扣減對應家庭的 `storage_used_bytes`，不需要為此另外寫任何程式碼。滿
     30 天後由§6「自動清除（LS-153）」既有的排程硬刪並入列 Storage 清除，沿用
     既有路徑，不在 `delete_my_account()` 這一層重做。
     `reactions`／`device_tokens` 仍然**刻意不在這支 RPC 觸碰的範圍**
     （`reactions` 沒有 soft delete 概念；`device_tokens` 的 FK 是
     `on delete cascade`，等真正刪除 `auth.users` 時自動清掉），見 migration
     檔頭「規格分歧與取捨」。
  無論走哪條路（情況 2／3），最後都會標記 `profiles.deletion_requested_at = now()`
  （情況 1 被拒絕時不標記）。
- **`auth.users` 的實際刪除不在本 RPC 範圍**：這支 RPC 是 `SECURITY DEFINER`，
  以呼叫者（`auth.uid()`）的身份判斷授權與範圍，但**不會**、也不能代表呼叫者去刪
  `auth.users`（那需要 `service_role`）。`profiles.deletion_requested_at` 是交給
  Edge Function `delete-account`（LS-151，`service_role` 執行，見§「Edge
  Functions」）的唯一契約欄位——那支流程驗證呼叫者 JWT、以 `service_role` 確認
  `deletion_requested_at is not null` 之後，呼叫 GoTrue admin API 刪除對應的
  `auth.users` 列（`profiles` 對 `auth.users` 是 `on delete cascade`，屆時
  `profiles` 列會跟著消失）。**這是 LS-143 當時刻意的取捨**：把「資料面處理」與
  「身份層真的刪除」拆成兩支獨立的部署單元（一支 SQL migration、一支 Edge
  Function），不在同一張票裡同時扛兩種截然不同性質的風險。
- **過渡狀態（merge-review R1 i1，實測確認）**：`delete_my_account()` 回傳成功
  之後、Edge Function 真正刪掉 `auth.users` 之前，這個帳號**仍是完全可用的登入
  身份**——`deletion_requested_at` 目前不被任何 RLS policy 或 grant 讀取，同一個
  `authenticated` 身分可以立即建立新家庭並成為新家庭的 owner、上傳照片等，「刪除
  帳號」對使用者不是一個立即生效的終態。**client 端硬性規定**：RPC 回傳後必須
  **立即**呼叫 Edge Function `delete-account` 完成 `auth.users` 的實際刪除，中間
  **不得允許使用者做任何操作**（不能停在「刪除中」畫面之外的任何互動）——這個窗口
  存在的唯一理由是兩支流程分屬不同部署單元、無法在同一個交易內完成，不是設計上
  允許使用者利用的正常狀態。**這個窗口內「又成為某個家庭的唯一 owner」的風險由
  LS-151 R2 用兩道防線處理**（merge-review R1 B1／M1，`20260903115014_delete_account_edge_support.sql`
  檔頭「R2」段落有完整訂正紀錄）——**R1 版本曾經在這裡宣稱「擋住 `family_members`
  的 INSERT，呼叫者在這個窗口內不可能再取得任何一列 `family_members`」，這句話
  被 reviewer 實測推翻**：`family_members` 的 UPDATE 路徑（既有的 owner 交接路徑）
  完全沒擋，且擋寫本身是快照讀、不取鎖，存在 READ COMMITTED 競態窗口。R2 訂正為：
  1. **第一道、真正的防線**：Edge Function 在呼叫 `service_role` 執行
     `delete from auth.users` 之前，先呼叫 `public.finalize_account_deletion(uid)`
     （同樣只授權 `service_role`）重跑一次資料面清理——不論下面第 2 點的擋寫有沒有
     漏洞，這一步都保證呼叫者在被真正刪除之前一定沒有任何一列 `family_members`
     （見下方「`finalize_account_deletion`」段落）。
  2. **第二道、縱深防禦**：`deletion_requested_at` 非 `NULL` 時，`family_members`
     的 `INSERT` 與 `UPDATE OF role, user_id` 一律拒絕（`LS051`，guard 查的是
     **被寫入的人**而不是操作者），`join_requests` 的 `INSERT` 也一併擋
     （`request_join`）——讓大多數情況下過渡期使用者連 UI 上的「建立新家庭」
     「等待審核」畫面都進不去，但**不是**「刪除一定成功」唯一依靠的機制。
  這兩道防線合起來讓 Edge Function 呼叫 `service_role` 執行
  `delete from auth.users` cascade 到 `family_members` 時不會撞見
  `private.enforce_family_has_owner()` 的 `LS001`（LS-143 merge-review R1 i1
  指出的原始風險）。
- **錯誤碼**：未登入 `42501`；唯一 owner 且家庭還有其他成員 `LS050`（見上方
  `DETAIL` 契約）。
- **併發（LS-155 R3 全面重寫；R1→R2→R3 三輪，每輪都是「證明少算一個入口」被
  merge-review 抓到，這次逐入口列出，不再籠統斷言）**：情況 1 的守門查詢刻意不
  額外加鎖，唯讀，不算入口。**情況 2／3 自 R3 起合併成單一 `family_id` 遞增序
  迴圈**（見下方「情況 2＋3」與 migration 檔頭「修訂歷史」的完整三輪記錄），
  每個家庭先鎖整個 `family_members`（`FOR UPDATE`，該家庭全部成員，不只是
  呼叫者自己）、再鎖 `families`（`FOR UPDATE`，理由見下）——不再有任何獨立於
  這個迴圈之外、會取得 `families`／`family_members` 鎖的邏輯。

  **逐入口列表**（本 repo 唯一會在同一支函式／trigger 內同時取得 `families` 與
  `family_members` 鎖的地方，`grep -n "for update\|for no key update\|for key
  share" supabase/migrations/*.sql` 核對過沒有遺漏；純粹只碰其中一張表、從不在
  同一交易內碰到另一張的呼叫端——例如 `families_update` policy 的 owner 改名
  ——不構成跨表交叉，不列入）：
  1. **本函式**——上述合併迴圈，每個家庭 `family_members` 先、`families` 後、
     `family_id` 全域遞增序。
  2. **`public.finalize_account_deletion()`**（`20260903115014_
     delete_account_edge_support.sql`＋`20260904080802_
     finalize_account_deletion_media.sql`）——自己的逐家庭迴圈，同樣
     `family_members FOR UPDATE` 先、`families FOR UPDATE` 後、`family_id`
     遞增序，家庭來源＝「p_user 現有家庭」∪「p_user 還有未軟刪 media 的家庭」。
  3. **`private.enforce_family_has_owner()`**（owner 不變量 trigger，
     `20260822120100_triggers.sql`，LS-6／LS-15，先於 LS-143／151／155 存在）
     ——掛在 `family_members` 的 AFTER STATEMENT（DELETE／UPDATE），觸發它的
     DML（本函式與 `finalize_account_deletion()` 的 `delete from
     family_members`、或使用者直接離開家庭／owner 轉移角色的 client 端
     UPDATE／DELETE）天生先鎖住自己正在改的 `family_members` 列，trigger 本身
     才對受影響的**每個**家庭（`distinct family_id from removed_members order
     by 1`）鎖 `families FOR NO KEY UPDATE`——這顆 trigger 正是「family_members
     先、families 後、遞增序」這套紀律最早的來源。
  4. **`public.approve_join()`**（`20260823010000_join_approval.sql`）——
     `INSERT INTO family_members` 只在新插入的那一列取鎖（新列，不與任何既有列
     的 `FOR UPDATE` 衝突），FK 參照完整性檢查對 `families` 取的是 `FOR KEY
     SHARE`（弱鎖，只與 `FOR UPDATE`／`FOR NO KEY UPDATE` 衝突，`FOR KEY
     SHARE` 之間互不衝突）——這支函式不會先鎖住任何既有 `family_members` 列、
     也不會反過來被上述「family_members 先」的順序卡住形成循環：它對
     `families` 的（弱）鎖與對 `family_members` 的（新列）鎖之間沒有跨交易的
     相依關係，只會被上述迴圈的 `families FOR UPDATE` 正常阻塞、不構成循環
     等待，見 `supabase/tests/concurrency/delete_account_vs_approve_join_*.sql`
     （LS-143 R2 m2）。

  **為什麼是 `FOR UPDATE`、不是 `FOR NO KEY UPDATE`**：合併迴圈內任何一個家庭
  都可能落入「唯一成員」分支而需要 `DELETE FROM families`——DELETE 終究需要
  `FOR UPDATE` 等級的列鎖，且這把鎖需要跟子表 INSERT（背景上傳、
  `approve_join()`）的 FK 檢查取的 `FOR KEY SHARE` 互斥，才能正確擋住「候選
  判斷用的是取鎖前的舊快照」這個競態窗——`FOR NO KEY UPDATE` 鎖不住 `FOR KEY
  SHARE`。

  **可證明不會死鎖**：兩個交易若都需要碰到同一組家庭集合 S，兩者對 S 的第一個
  動作永遠是 `family_members(min(S))`（單一互斥資源），先搶到的一方會暢通無阻
  跑完 S 的其餘部分（輸家此時手上一無所有，擋不住贏家），不會出現循環等待——
  前提是每一個入口對 S 的處理都遵守同一個遞增序、且不會在跨到下一個家庭之前就
  去摸更後面家庭的 `families`，這正是上面四個入口都遵守的紀律。

  **三輪修訂記錄**（migration 檔頭有完整版，這裡只列結論；每一輪都是被
  merge-review 實測重現 40P01 抓到的真問題，不是理論推演）：
  - R1（merge-review R1 M1）：新增的 media `UPDATE` 對「呼叫者已退出但留有
    media」的家庭是本交易唯一一次觸碰、且是「`families` 先、`family_members`
    後」——與 `finalize_account_deletion()` 鎖序相反，三連線實測 40P01。
  - R2 中間版本（自己的常駐迴歸測試抓到）：把 media 迴圈加在「離開剩餘家庭」
    DELETE **之後**仍不夠——DELETE 只碰「呼叫者仍是成員」的家庭，跟 media 迴圈
    涵蓋的「已退出但留有 media」家庭是兩個各自遞增序、但涵蓋不同子集的迴圈，
    合起來不是全域遞增序（A-X vs X-A 交叉），同一組三連線**仍然**死鎖。
  - R2 送審版本（merge-review R2 R2-M1）：情況 3 已經合併成單一迴圈，但**情況
    2（唯一成員家庭）當時仍在迴圈之外**（先鎖 `families`、迴圈結束後才批次
    `delete from families` cascade 才碰 `family_members`）——跟情況 3 合併
    迴圈、`finalize_account_deletion()` 的「`family_members` 先」相反，且情況
    2／3 又是兩個涵蓋不同子集的遞增序迴圈，合起來不是全域遞增序。reviewer 用
    N1（人工撐窗）／N2（U1 自己的背景上傳佔另一家庭的 `families` 列鎖，真實
    行為不需要人工鎖）兩種方式各重現一次 40P01。
  - **R3（本版）**：情況 2 併進同一個遞增序迴圈——不再有任何獨立於這個迴圈之外
    的入口。**LS-143 R2 m2「候選家庭鎖內用全新查詢重新評估唯一成員」的兩段式
    語意原樣保留**：候選集合仍是取鎖前的快照，只有「快照當時就已經是候選」的
    家庭，鎖到之後才會重新驗證是否仍是唯一成員、通過才 cascade；不是候選的
    家庭（或候選但重新驗證失敗）一律走情況 3 的一般離開路徑——這條界線是
    `supabase/tests/concurrency/delete_account_race_*.sql`（兩位共同 owner
    同時刪帳號、後動者須拿到 `LS001` 重試）成立的前提，若對每個家庭都無條件
    重新判斷唯一成員，這個既有測試的行為會改變（R3 開發過程中先寫過這個更
    簡單的版本，這個既有測試直接炸掉，逼出候選快照保留設計，見 migration
    檔頭）。

  常駐迴歸測試（皆重現對應輪次 reviewer 的實測時序，最終版修後不死鎖）：
  `supabase/tests/concurrency/delete_account_vs_finalize_media_*.sql`（R2-M1，
  三連線）、`delete_account_case2_vs_media_*.sql`（R2-M1 續／R3，N2 真實在飛
  上傳撐窗，三連線，沿用同一支 `race_case3` runner）。R1／中間版本／R2 送審
  版本跑同一組時序皆會 40P01，已於各輪 handoff 一次性驗證，不留在常駐測試裡。

  `finalize_account_deletion()` 本身在 R2 同一輪訂正：`20260904080802_
  finalize_account_deletion_media.sql` 讓它在既有的逐家庭迴圈裡多做一步同樣的
  media 軟刪（家庭列表擴充為「呼叫者現有家庭」∪「呼叫者還有未軟刪 media 的
  家庭」，仍是單一遞增序迴圈，不是另開迴圈），接住 `delete_my_account()` 交易
  提交窗口內在飛上傳留下的孤兒列（merge-review R1 m2，見下方「過渡狀態」段落
  與 §「Edge Functions」）。

### `accept_eula(p_version text) -> void`（LS-197，PLAN §6 第 7 項／§10-B）
- **誰能呼叫**：任何已登入使用者，**包含被停權的使用者、以及被停權家庭裡的
  成員**——同意條款不是內容寫入，函式寫入的 `profiles` 沒有掛
  `private.enforce_not_suspended()`（見 §3 `profiles` 的 `suspended_at`
  範圍說明），不需要比照 `delete_my_account()` 另外開交易級 GUC 逃生口。
- **用途**：紀錄呼叫者同意 `p_version` 版本的 EULA。`p_version` 必須等於呼叫
  當下的 `app_settings.eula_version`（`authenticated` 對這一欄有欄位級
  `SELECT`，呼叫端應先讀這個值再顯示條款內容、決定要送哪個 `p_version`），
  相符才寫入 `profiles.eula_accepted_version`／`eula_accepted_at`（`now()`）。
  **client 讀 `eula_version` 時不得帶 `where id = true`**（或任何引用到 `id`
  的條件）——Postgres 的欄位級權限檢查涵蓋查詢裡任何位置引用到的欄位，不只是
  投影出來的欄位，`id` 沒有 `SELECT` 權限，WHERE 子句用到它一律 `42501`
  （`permission denied for table app_settings`）；本表只有一列，直接
  `select eula_version from app_settings limit 1`（supabase-swift：
  `.from("app_settings").select("eula_version").limit(1)`）即可，不需要、也
  不能篩 `id`。§11「查目前狀態」那些帶 `where id = true` 的查詢是表擁有者
  （postgres）身分執行，不受這道欄位級 grant 限制，兩者是不同的執行身分，
  不能照抄。
- **冪等**：同版本重複呼叫不報錯，`eula_accepted_at` 覆寫成最新一次呼叫的
  時間——沒有「已同意過就整支跳過」的分支，需求是留下「最近一次確認過條款」
  的時間戳。
- **錯誤碼**：未登入 `42501`；`p_version` 與目前 `eula_version` 不相符
  `LS055`（呼叫端多半是讀到的版本已經過期，該重新抓一次目前版本、重新顯示
  條款）；`auth.uid()` 沒有對應的 `profiles` 列 `LS056`（R2，理論上不該發生
  ——LS-110 保證每個帳號都有一列 `profiles`，出現代表資料不一致，不是使用者
  能自己解決的狀態）。
- **併發**：單一 `SELECT` 讀目前版本＋單一 `UPDATE` 寫自己的 `profiles` 列，
  不取任何額外鎖；`app_settings.eula_version` 在讀取後、寫入前被改動不構成
  資料不一致——這次呼叫本來就是「使用者同意了他讀到的那個版本」，不是
  「使用者同意了資料庫目前這一刻的版本」，跟其他使用者或後續請求互不影響。

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
| `LS026` | 留言／按讚／檢舉的 target 存在，但屬於別的家庭 | `create_comment`／`toggle_reaction`／`report_content`（LS-149，同一種目標歸屬檢查，見 §4） |
| `LS027` | 這篇日記／這本相簿／這則留言已被家庭管理者移除，只有管理者能還原 | `set_diary_deleted`／`set_album_deleted`／`set_comment_deleted`（還原方向或重新軟刪方向皆可能；albums 的建立者直接 `.update()` 路徑也會撞到；由 `private.enforce_deletion_attribution()` trigger 統一 raise，LS-57，PR #98 review 擴大到重新軟刪方向並涵蓋 `deleted_by` 為 `NULL` 的情況） |
| `LS041` | 孩子檔案不存在，或（`update_child` 情境）已被軟刪除須先還原 | `update_child`／`set_child_deleted` |
| `LS042` | 不是仍是該家庭 owner/member 的成員，無法編輯孩子檔案 | `update_child` |
| `LS043` | 孩子檔案已被移除超過 30 天，無法還原 | `set_child_deleted`（`p_deleted = false`） |
| `LS044` | 寶貝已移除，無法歸屬新內容 | `diary_children`／`album_children` 的 `BEFORE INSERT` trigger（LS-121 起搬到連結表；原本掛在 `diaries`／`albums` 本體，見 §8）——`create_diary_entry`／`update_diary_entry`／`set_album_children`（`p_child_ids` 任一元素指向已軟刪的孩子）皆可能撞到，這是這支 trigger 唯一會被觸發的路徑（`diary_children`／`album_children` 對 `authenticated` 沒有任何直接寫入 grant，見 §2／§3，不存在繞過三支 RPC 直接撞到這個碼的呼叫端路徑）；只在真的要新增一列標記時才會觸發，不影響既有標記繼續存在、既有內容繼續軟刪／還原／編輯自己（見 §8） |
| `LS045` | 不是相簿建立者本人，或雖是建立者但已不是該家庭 owner/member，無法設定寶貝標記 | `set_album_children`（LS-121） |
| `LS050` | 你是家庭的唯一 owner，且家庭還有其他成員，須先轉移 owner 身份才能刪除帳號——`DETAIL` 帶 JSON 陣列列出全部需要轉移的家庭（`[{"family_id","family_name"}, ...]`），見 §4 `delete_my_account` | `delete_my_account`（LS-143） |
| `LS051` | 帳號已請求刪除（`deletion_requested_at` 非 `NULL`），過渡期間不能再建立新資料——沒有輸入可換，只能等 Edge Function `delete-account` 完成刪除 | `families`／`family_members`／`media`／`diaries`／`albums`／`children`／`comments` 的 `BEFORE INSERT` trigger（`private.enforce_account_not_deletion_requested()`，LS-151），涵蓋直接 `.insert()` 與 `create_child`／`create_diary_entry`／`create_comment`／`approve_join`／建立新家庭自動寫入 owner 等 RPC 路徑，見 §2「過渡期擋寫」 |
| `LS052` | 這個帳號已被暫停使用，請聯絡我們 | `profiles.suspended_at` 非 `NULL`（Dashboard 手動停權，PLAN §10-B，LS-179）時：(a) `private.enforce_not_suspended()`——掛在 `family_members`／`invites`／`children`／`media`／`albums`／`album_media`／`diaries`／`diary_media`／`diary_children`／`album_children`／`comments`／`reactions`／`content_reports`／`blocked_users`／`join_requests` 十五張表的 `BEFORE INSERT/UPDATE/DELETE`，涵蓋直接 `.insert()`/`.update()`/`.delete()` 與全部 `SECURITY DEFINER` RPC（trigger 不受 `SECURITY DEFINER` 影響——**`delete_my_account()` 是唯一的例外**，R2 見 §4，永遠豁免這個檢查）；(b) `private.enforce_caller_not_suspended_for_families()`——`families` 的 `BEFORE INSERT`（自建新家庭）；(c) `list_join_requests`／`get_my_join_request`／`list_comments` 三支唯讀 `SECURITY DEFINER` RPC 各自的明確檢查（這三支沒有寫入、又繞過 RLS 讀，前兩種機制都碰不到）。**讀取（SELECT）與 Storage 簽名上傳**：透過 `private.family_ids()`／`owned_family_ids()`／`contributor_family_ids()`／`uploadable_family_ids()` 四支集合函式收斂，停權者這四個集合皆為空，對應的 `_select` policy 與 `storage.objects` 四條 policy 靜默回 0 列／`42501`，不會有 `LS052`（RLS 違反沒有自訂碼這條路）；`content_reports_select`／`join_requests_select`／`families_select` 的「自己那一支」分支（R2 訂正，見 §3）也已補上同一組排除 |
| `LS053` | 這個家庭已被暫停使用，請聯絡我們 | `families.suspended_at` 非 `NULL`（Dashboard 手動停權，PLAN §10-B，LS-179）時，觸發路徑同 `LS052` 的 (a)／(c)（家庭停權只影響該家庭本身的資料，成員對其他家庭不受影響，`delete_my_account()` 同樣豁免，見 §4）；讀取與 Storage 同樣經四支集合函式收斂成 0 列／`42501` |
| `LS054` | 目前暫停開放新註冊，請稍後再試 | `private.enforce_registrations_open()`——`families` 的 `BEFORE INSERT`（自建新家庭），`app_settings.registrations_open = false` 時觸發（PLAN §10-A(3)，LS-179）。**只擋自建新家庭**：憑邀請碼加入既有家庭（`request_join`／`approve_join`）不碰 `families` 表，不受影響 |
| `LS055` | 條款版本已更新，請重新閱讀 | `accept_eula(p_version)`——`p_version` 與呼叫當下的 `app_settings.eula_version` 不相符時觸發（LS-197，PLAN §6 第 7 項／§10-B）。呼叫端多半是讀到的版本已經過期，該重新抓一次目前版本、重新顯示條款內容 |
| `LS056` | 帳號資料異常，請聯絡我們 | `accept_eula(p_version)`（LS-197 R2，merge-review R1 m2）——寫入 `profiles.eula_accepted_version`／`eula_accepted_at` 的 `UPDATE` 命中 0 列時觸發，代表 `auth.uid()` 沒有對應的 `profiles` 列。理論上不該發生（LS-110 的 `auth.users` insert trigger 保證每個帳號都有一列 `profiles`），出現代表資料不一致，fail loud 而不是靜默 no-op |
| `42501` | 未登入，或權限不足（不是該家 owner／不是申請人本人／不是作者本人／作者已離開家庭／不是該家任一角色成員／直接寫入被 grant 擋下／`family_id` 不可變 trigger 擋下） | 所有 RPC 皆可能；也是**任何直接對 RPC-only 表寫入**（如 `family_members` INSERT、`invites` INSERT/UPDATE、`join_requests` 任何寫入、`diaries` INSERT/UPDATE、`comments` INSERT/UPDATE、`reactions` INSERT/DELETE、`children` INSERT/UPDATE/DELETE——`children` 的 `DELETE` 自 R1 I5 起也收斂，連 owner 都拿這個碼）會拿到的標準碼；也是 `diaries`／`albums`／`comments`（`private.enforce_deletion_attribution()`，LS-57）與 `children`（`private.enforce_children_family_immutable()`，LS-66，LS-57 R2／I1 對齊後改用裸 `42501`，不再是原本 LS-66 定案時的專屬碼）的 `family_id` 不可變 trigger 統一 raise 的碼；`albums` 直接 `.update()` 竄改 `deleted_at`／`deleted_by`／`family_id` 三欄自 LS-57 R2 起也在欄位級 grant 被收回，同樣回這個碼（見 §2/§3）——PostgREST 對 grant 被收回的操作回這個碼，訊息只會是通用的 permission denied，不會有自訂文字，trigger 主動 raise 的則帶自訂中文訊息，但 SQLSTATE 一樣是 `42501`。**例外**：owner 對別人的 `albums` 直接 `.update()` 內容欄位**不會**拿到這個碼，是靜默影響 0 列，見 §2「寫入路徑小結」的例外說明（`comments` 自 LS-58 起不再適用這條例外，直接 `.update()` 一律 `42501`） |

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
被竄改的訊號，不是「換個輸入再試」能解的，UI 該做的是回上一頁或重新整理而不是原地重試）、
`LS027`（LS-57 補齊，歸層 `rejected`——作者想還原 owner 移除的內容，沒有輸入可換，只有
owner 能還原）、`LS041`–`LS043`（LS-66 補齊，歸層皆 `rejected`——`LS041`／`LS042`
分別對齊 `LS020`／`LS021` 的理由；`LS043`（還原超過 30 天）換輸入或重試同一個呼叫都
不會成功，UI 該做的是不再顯示「還原」這個動作。原本的 `LS040`（孩子檔案 `family_id`
不可變 trigger 防護）已於 LS-57 R2／I1 撤碼，改用跟 `diaries`／`albums`／`comments`
一致的裸 `42501`，不再是 `LSErrorCode` 的一個 case）、`LS044`（R1 補齊，歸層
**`validationRetryable`**——跟上面幾碼不同層：`p_child_id` 是使用者從孩子清單挑出來的
輸入，跟 `inviteCodeNotFound` 那組同一類，挑到的孩子剛好已被軟刪多半是清單快取過期，
換一個沒被軟刪的孩子（或不指定）之後同一個 `create_diary_entry`／`update_diary_entry`
呼叫就會成功，符合「使用者能換輸入」的 `validationRetryable` 準則——R2（merge-reviewer
PR #95 review F1）訂正：這裡原本誤寫成跟 `LS041`–`LS043` 一起歸 `rejected`，與
`LSErrorCode.tier` 的 `case .childDeletedCannotAttachContent` 實際回傳的
`validationRetryable` 矛盾，以程式碼（`AppErrorTests.swift` 的列舉測試釘住）為準）；
`LS016` 另於 LS-55 從 `validationRetryable` 改歸新增的 `retryableSystem` 層（見上方 `LS016`
列註記）。`LS045`（LS-121 補齊，歸層 `rejected`——不是相簿建立者本人、或雖是建立者
但已不是該家庭 owner/member，同 `LS021`／`LS025`／`LS042` 同一類：換輸入沒有用，UI
該做的是隱藏「編輯寶貝標記」入口）。`LS050`（LS-143 補齊，歸層 `rejected`——你是
家庭唯一 owner 且家庭還有其他成員，沒有輸入可換，必須先做別的事（把 owner 身份
轉移給其他成員），跟 `familyMustHaveOwner`（`LS001`）同一組理由，只是觸發路徑
不同：一個是直接對 `family_members` 做會導致 0 owner 的操作，一個是呼叫
`delete_my_account()`）。`LS051`（LS-151 補齊，歸層 `rejected`——帳號已請求刪除，
過渡期間的寫入一律拒絕，沒有輸入可換、也沒有使用者能自己做的「別的事」，只能等
Edge Function 完成刪除）。`LS052`／`LS053`／`LS054`（LS-179 補齊，歸層皆
`rejected`——三者都是狀態層級的拒絕，沒有輸入可換：`LS052`／`LS053`（帳號／家庭
被停權）只能等 Dashboard 解除；`LS054`（暫停開放新註冊）只能等關閉的旗標重新
打開，跟 `LS051`（過渡期擋寫）同一組「純狀態拒絕、沒有使用者能自己做的別的事」
的理由）。`LS055`（LS-197 補齊，歸層 `rejected`——`p_version` 與目前
`eula_version` 不相符，沒有「打錯字重打」這種輸入可換，正確動作是重新抓一次
目前版本、重新顯示條款，不是原地拿同一個 `p_version` 重試，跟 `LS052`–`LS054`
同一組「純狀態拒絕」理由）。`LS056`（LS-197 R2 補齊，歸層 `rejected`——
`auth.uid()` 沒有對應的 `profiles` 列，理論上不該發生，沒有輸入可換、也不是
使用者能自己解決的狀態，只能聯絡我們排查）。三層（`validationRetryable`／`retryableSystem`／
`rejected`）歸類由 `LittleSproutTests/AppErrorTests.swift` 的列舉測試逐碼釘住。
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
- **縮圖產生規格（LS-128，客戶端契約，DB 不驗內容只驗路徑與尺寸為正）**：長邊
  ≤ 512px、JPEG 品質 0.8；來源是影片（`type = 'video'`）時取**首幀**、依同規格轉成
  JPEG（縮圖副檔名恆為 `.jpg`，不隨原始檔案型別變化）。縮圖與原始檔案同步產生、
  同步 PUT 進 Storage，寫入路徑對應 `public.media.thumb_path`（見上方 `media` 表，
  §3）；`thumb_width`／`thumb_height` 填縮圖實際輸出的像素寬高，不是原圖的等比縮放
  理論值。
- **寶貝大頭照（LS-169）：`{family_id}/avatars/{child_id}.jpg`**——與上面「原始檔案／
  縮圖」是同一個路徑規約判斷式 `private.is_media_object_path()` 並列的第二種合法
  形狀（`supabase/migrations/20260904060700_avatar_object_path.sql`），但**不寫**
  `public.media` 表（不是任何一筆 `media` 列的 `storage_path`／`thumb_path`，不計入
  額度、不會出現在時間軸／相簿），路徑直接寫進 `public.children.avatar_url`（PUT
  語意，見 `update_child`）。`{family_id}`／`{child_id}` 一律小寫正規形 UUID（同上
  ——`children.id` 由 Postgres 產生，`uuid::text` 輸出恆為小寫；Swift 端一樣要
  `.lowercased()`）；副檔名固定 `.jpg`（客戶端裁方成正方形、縮到 512×512、JPEG
  品質 0.8 後上傳，不像原圖／縮圖那樣接受多種格式）。換照片＝對同一個路徑
  `upsert: true` 覆蓋上傳，不是每次都開新路徑；讀取同樣走短效簽名 URL（同
  `thumb_path` 的既有慣例，見下方「簽名 URL 與 egress 防線」）。**第一次上傳（INSERT）**
  沿用既有 policy 的 `uploadable_family_ids()`（owner 恆可；member 看 `can_upload`）；
  **RLS 的 UPDATE／DELETE policy 角色判準改用跟 `update_child` 相同的判準**
  （`private.contributor_family_ids()`：owner／member 皆可、不看 `can_upload`，見下方
  RLS 表——孩子頭像是家庭共有物，不是上傳者個人物件，`storage.objects.owner`
  對這個路徑形狀不再有意義；`supabase/migrations/20260904081435_avatar_family_write_policy.sql`，
  LS-169 R2 M1）。**但這條放寬不等於「can_upload=false 的成員也能換頭像」**（LS-169
  R3 n1）：client 換頭像唯一會走的路徑是 Storage API 的 `upsert: true`，storage-api
  內部等同 `INSERT ... ON CONFLICT DO UPDATE`，一定會先過 INSERT policy 的
  `WITH CHECK`——INSERT 分支本輪刻意沒有放寬（仍是 `uploadable_family_ids()`，member
  看 `can_upload`），理由是「不能上傳照片的成員也不該能上傳頭像」語意要一致。結果是：
  `can_upload=false` 的 member 用真實 app 換頭像會在 INSERT policy 被擋
  （400 `new row violates row-level security policy`，`ChildAvatarUploadService`
  的 `mapUploadError` 會把它映射成 `.rejected` 給出明確文案）；放寬的 UPDATE／DELETE
  判準對 app 的 upsert 覆蓋路徑生效（member 可換 owner 上傳的頭像）；INSERT 仍需
  `can_upload`（LS-169 R3 merge-review `038c3e12` n3 訂正：先前這裡講反了——實跑證明
  `role=member, can_upload=true` 的 B 確實能用真實 upsert 覆蓋 owner A 上傳的頭像，
  放寬前 400、放寬後 200）。
  客戶端固定路徑＋長效快取意味著換照片後簽名 URL 需要 cache-busting 才能讓列表立即
  顯示新圖，見 `ChildrenStore.avatarCacheBust` 文件註解。

### storage.objects 的 RLS（四條 policy，皆 `to authenticated`）

| 操作 | 誰可以 | 額外限制 |
|---|---|---|
| SELECT | 同家庭任何角色（含 viewer） | 只看得到路徑第一段＝自己所屬家庭的物件；不檢查路徑規約，讀取端不因格式問題被擋 |
| INSERT | 有上傳權者（owner 恆可；member 看 `can_upload`；viewer 不行） | 路徑必須符合規約且第一段＝自己**當下**所屬的家庭（防跨家庭寫入）；`owner`/`owner_id` 欄位（storage-api 自動填）必須是自己或留空 |
| UPDATE | 家庭 owner（任意物件）；或上傳者本人（僅限**當下**仍有上傳權時）；**頭像路徑（`avatars/{child_id}.jpg`）另加一個分支：仍是該家庭 owner／member 者，不看 owner／owner_id／can_upload**（LS-169 R2 M1，與 `update_child` 同一判準；**但 client 只會經由 upsert 觸發，upsert 同時要過 INSERT policy——`can_upload=false` 的 member 在真實上傳路徑仍會被擋，見上方「寶貝大頭照」小節，LS-169 R3 n1**） | 新路徑同樣要通過規約與家庭歸屬檢查（防止「改名搬家」繞過 INSERT 邊界） |
| DELETE | 同 UPDATE 的判準（含頭像路徑的家庭角色分支） | 上傳者可以刪自己上傳的孤兒物件（見 §3 `media` 的「上傳流程順序」）；已軟刪除的 `media` 對應物件**不要**跟著硬刪 Storage 檔案（PLAN §5：軟刪除要留救援路徑；30 天後的自動永久清除見下方「自動清除（LS-153）」——那是 service_role／背景排程的路徑，不經這四條 policy） |

- **`can_upload` 被收回後的行為是「當下判斷」不是「上傳當時判斷」**：owner 把某成員的
  `can_upload` 關掉之後，那個人連自己以前上傳的檔案都改／刪不了——這是刻意選的較嚴
  一邊，代價是「被撤權成員留下的孤兒物件改由家庭 owner 清理」，寫進這裡供 UI 文案
  參考（例如撤銷上傳權的確認對話框可以提一句）。
- **簽名 URL 與 egress 防線**（PLAN §7／§8：長輩會反覆滑同一批照片，這項比想像中容易
  吃流量）：時間軸列表（`get_family_timeline` 消費者依 §4 分組批次查 `media` 那一支）、
  日記詳情的照片牆、相簿列表一律用 `media.thumb_path`（有值時）簽名 URL；全尺寸原檔
  （`media.storage_path`）**只在放大檢視／影片播放時**才簽。**`thumb_path` 為 `NULL`
  時**（既有資料、縮圖產生失敗的過渡列，見上方 `media` 表）**退回 `storage_path`
  簽名 URL**——不要因為沒有縮圖就整列不顯示。這是 client 實作責任，DB 只保證
  `thumb_path` 有值時的路徑格式與尺寸合法（LS-128 的 `CHECK`），不保證、也無法保證
  誰在什麼時候簽了哪一個路徑。
- **影片時長徽章讀取策略（`duration_seconds`，LS-134）**：時間軸／相簿列表的影片卡
  「影片 M:SS」徽章一律**直接讀 `media.duration_seconds` 查表值**，不對縮圖或原圖
  做媒體解碼（縮圖是 JPEG 靜態圖，`AVURLAsset.load(.duration)` 對它本來就量不出時
  長——這正是 LS-130 徽章退化成純文字「影片」的成因）。`duration_seconds` 為 `NULL`
  時（既有 video 舊資料、上傳端量測失敗的過渡列）**退回純文字「影片」**（無時長字
  樣），不要為了補這個徽章去簽全尺寸原圖做客戶端解碼——那正是本欄位存在的目的：
  用一次 DB 查詢換掉一次全尺寸 egress。與下方 LS-130 的縮圖優先簽名策略互補：即使
  `duration_seconds` 缺失，也只會讓徽章退化成純文字，不會反過來觸發全尺寸簽名。
  **iOS 消費者現況（LS-130／LS-135）**：時間軸卡片流（`TimelineContentAssembler.
  fetchDiaryContents`／`fetchAlbumContents`／`fetchMediaContents`，經 `PrintPhotoCard.
  remoteURL` 呼叫端 `AlbumCardView`／`PhotoCardView`／`DiaryCardView` 顯示）與日記詳情瀑布流
  （`fetchDiaryPhotos`，`MasonryPhotoWallView` 顯示；比例改用 `thumb_width`／`thumb_height`，
  同一條 NULL 退回規則）已落地，全尺寸原檔改由 `TimelineStore.signFullSizeURL(storagePath:)`
  在播放影片當下現簽（`DiaryDetailView.playVideo`）——影片時長徽章不依賴這裡簽出的 URL，
  改查上方「影片時長徽章讀取策略」的 `media.duration_seconds`。**LS-135 起**：`MediaRow`／
  `MediaContent` 帶 `durationSeconds`（`.select()` 選 `*`，隨既有查詢一起回來，不需要另外的
  RPC 或欄位級 grant），`TimelineStore.displayDuration(for:)` 優先讀這個值，`nil`（LS-135
  之前上傳的舊列、或上傳端量測失敗的過渡列）才退回 `MediaContent.needsVideoDurationLookup`
  （`type == .video && !isThumbnail && durationSeconds == nil`）判斷是否要對 `signedURL`
  現讀 `AVURLAsset.load(.duration)`——`isThumbnail` 為 `true` 的縮圖列一律不查，即使
  `durationSeconds` 也是 `NULL`。**相簿列表畫面尚未實作**（LS-126 票文「不做：相簿畫面」）
  ——本節這條規則在契約層面已對它生效，待該畫面實作時比照 `fetchAlbumContents` 的
  `displayPath` 選路寫法即可，不需要另外裁決簽名策略。

### 自動清除（LS-153）

實作於 `supabase/migrations/20260903110908_purge_expired.sql`。承接上方「軟刪除要留
救援路徑」與 §3 `children` 的「30 天可還原」——這裡是那個窗口關閉之後真正發生的事：
**系統每日自動、永久清除超過 30 天的軟刪／刪除帳號請求資料**，不是人工作業（隱私
政策 LS-132 §8 的承諾字面），也不是即時清除（軟刪的當下不會立刻清，永遠先給 30 天
救援窗）。

**清除規則**：`private.purge_expired(p_now timestamptz default now())`（`private`
schema，`security definer`，只 `service_role`／`pg_cron` 可呼叫，`authenticated`
沒有 `EXECUTE`——不是一支 API，不會出現在 §9 的 RPC 對帳清單）逐一硬刪以下六張表裡
`deleted_at`／`deletion_requested_at` **早於 `p_now - 30 天`**（嚴格早於——剛好 30
天前不算超過，語意對齊 `set_child_deleted` 的 30 天還原邊界判準）的列：

| 表 | 判準欄位 | 備註 |
|---|---|---|
| `diaries`／`albums`／`comments` | `deleted_at` | 一般軟刪／owner 移除都算；硬刪後順帶清掉指向它們的孤兒 `comments`／`reactions`（多型關聯沒有 FK，父列消失不會自動帶走，見下方「孤兒 comments／reactions」） |
| `media` | `deleted_at` | 軟刪來源含使用者自己刪照片／影片，以及（LS-155 起）`delete_my_account()` 對呼叫者上傳、仍存在的每張 media 一併軟刪（不限定呼叫者是否仍是該家庭成員，見 §4「併發」）；`finalize_account_deletion()`（LS-155 R2）在同一個逐家庭迴圈重跑一次同樣的軟刪，接住交易提交窗口內在飛上傳的孤兒列；硬刪由 `private.media_storage_queue_sync()`（media 的 AFTER DELETE 統計級 trigger，R2）收 `storage_path`／`thumb_path`（非 NULL 者）進 `public.purge_storage_queue`，交給下方 Edge Function 實際刪除 Storage 物件——**不論這句硬刪是 `purge_expired()` 自己執行、還是被 `delete_my_account()` 情況 2 的 `families` cascade 觸發，都會入列**（R2 修正：R1 版本只在 `purge_expired()` 自己的 DELETE 裡入列，cascade 硬刪的 media 完全漏收，見下方「情況 2 cascade 與 Storage 佇列」）；`families.storage_used_bytes` **不會**在這裡再扣一次額度——軟刪的當下（`deleted_at` 從 `NULL` 變成非 `NULL` 的那次 UPDATE，含 LS-155 這句）就已經被 `private.media_storage_sync()` 扣過，硬刪時這批列的 `deleted_at` 皆非 `NULL`，同一支 trigger 的 DELETE 分支明確只對 `deleted_at is null` 的列計入扣除金額，重複硬刪不會重複扣 |
| `children` | `deleted_at` | 與 §3「30 天可還原」窗口共用同一個判準；硬刪會 cascade 掉 `diary_children`／`album_children`／`feed_item_children` 裡指向這個孩子的既有標記；`children` 不是 `content_target_type` 合法值，沒有孤兒 `comments`／`reactions` 要清 |
| `profiles` | `deletion_requested_at` | **R2 起是 tombstone，不是硬刪**，見下方「`profiles` tombstone：為什麼不硬刪」 |

`families` 本身**沒有**進這張清單——它沒有 `deleted_at` 欄位（從第一天的 schema 就
是如此），家庭整體刪除（`delete_my_account()`，LS-143，唯一成員情況）是呼叫當下
**立即** cascade 硬刪，不是先軟刪等 30 天；這比本節的 30 天窗口更嚴格，不需要、也
不應該被放寬成「等 30 天」。

**情況 2 cascade 與 Storage 佇列**（R2，merge-review R1 F1）：`delete_my_account()`
情況 2（呼叫者是某家庭唯一成員）在 RPC 呼叫的當下就對 `families` 下一句 `DELETE`，
FK cascade 一路連坐到 `media`——這條路徑完全不經過 `purge_expired()`。Storage 路徑
入列邏輯因此不能只寫在 `purge_expired()` 自己那句 `media` `DELETE` 的 CTE 裡（R1
的做法，會讓單人家庭刪帳號留下的照片 Storage 物件永遠清不到），改成獨立掛在
`media` 本身的 AFTER DELETE 統計級 trigger（`private.media_storage_queue_sync()`，
`referencing old table`）——不論 `media` 是被誰、從哪個上游 DELETE 連坐硬刪的，
Postgres 都會在 `media` 這一層補一次 AFTER DELETE 事件，trigger 都會執行到。這支
trigger 對「任何硬刪的 `media` 列」都入列，不像 `purge_expired()` 自己那句 DELETE
只挑 `deleted_at` 過期的列——情況 2 的 cascade 硬刪對象不限於已軟刪的照片（唯一
成員刪帳號時，家庭底下所有照片不論軟刪與否都會被 cascade 掉），兩者判準本來就該
不同。

**孤兒 comments／reactions／content_reports／notification_events**（R2 minor
finding；R3，merge-review R2 F2／F3，comment 7420f7b9；R4，merge-review R3
minor 1，comment `04987043`）：`comments`／`reactions`／`content_reports`／
`notification_events` 四張表都是多型關聯（`target_type`／`target_id`），刻意
沒有 FK（PLAN §5 已知代價）——`diaries`／`albums`／`media`／`comments` 被硬刪
之後，指向它們的留言／按讚／檢舉／通知事件不會自動消失，`purge_expired()` 在
硬刪這四張表各自的過期列之後，順帶清掉 `target_type`／`target_id` 指向那些剛
消失的 id 的這四張表（含「留言掛在已消失的留言下」這個防禦性分支——今天沒有
留言回覆留言的功能，預期永遠 0 筆，保留是因為多型 target 沒有 FK，寧可多做
一次涵蓋）。`deleted_counts` 裡的 `comments`／`reactions` 兩個鍵是**累加值**：
自己過期的直接刪除數，加上依附在其他表清除時一併清掉的孤兒數（`content_reports`
與 `notification_events` 都沒有進 `deleted_counts`，純粹清除、不觀測筆數，同
「不擴大範圍」的既有原則）。

**第二層孤兒（R3，F2；R4，minor 1）**：`diaries`／`albums`／`media` 的孤兒留言
被清掉之後，指向「那則留言」本身的按讚／檢舉／通知事件會變成第二層孤兒（留言
消失了，但誰對它按過讚／檢舉過／收到過通知的紀錄還在）——`purge_expired()` 用
`delete … returning id` 把孤兒留言自己的 id 收出來，再清一次 `target_type=
'comment'` 的 `reactions`／`content_reports`／`notification_events`。

**`content_reports`／`notification_events` 的處置（R3 F3／R4 minor 1，
orchestrator 裁定）**：R1 review 點名 `content_reports` 是三張孤兒表之一，R2
只修了 `comments`／`reactions`；R3 補上 `content_reports`（票的承諾是「永久
清除」，`reason` 是使用者輸入的自由文字，屬使用者資料，不該是留下的例外）之後，
R3 review 又實測出 `notification_events` 是**第五張**同形狀的多型孤兒表（
`target_type`／`target_id` 欄位與 `content_reports` 完全一樣），R2／R3 都沒
處理到——orchestrator 裁定比照 `content_reports` 一併清除，而不是留成例外。
現況：`comments`／`reactions`／`content_reports`／`notification_events` 四張
表指向已永久清除目標的列，涵蓋四種 `target_type`（`diary`／`album`／`media`／
`comment`，含直接過期與孤兒清除兩種消失方式），**都會**被 `purge_expired()`
一併清除——不再有「唯一例外」這種措辭需要維護，因為現在沒有例外。

**`profiles` tombstone：為什麼不硬刪**（R2，merge-review R1 F2，取代原本「硬刪、
留孤兒 auth.users」的版本；規格分歧仍是採最保守解，見 migration 檔頭完整說明）：
超過 30 天的 `profiles` **不再硬刪**，改成**清空 PII（`display_name`／
`avatar_url`）並標記 `purged_at`**，列本身保留。理由：`delete_my_account()`
（LS-143）回傳後，client 依 §4 契約必須立即呼叫 Edge Function `delete-account`
（LS-151，`service_role`）刪除 `auth.users`（`profiles` 隨 cascade 一併消失）——
正常路徑下 `profiles` 活不到 30 天，這裡的 30 天處理是那條路徑失敗時（client
crash、網路斷線、Edge Function 本身出錯）的最後防線，隱私政策承諾的是「使用者
資料 30 天內清除」，tombstone 已經把可辨識 PII 清空，即使 `auth.users` 因為
LS-151 尚未成功而暫時還在，也不構成資料外洩。**不能硬刪的實測理由**：
`SupabaseFamilyAPIClient.ensureProfileExists`
（`LittleSprout/Services/Family/SupabaseFamilyAPIClient.swift:51-58`）用
`upsert(payload, onConflict: "id", ignoreDuplicates: true)`——PostgREST 端等同
`insert ... on conflict (id) do nothing`。若 `profiles` 列真的被硬刪（id 不存在），
這句 upsert 會走「不存在」分支，對同一個尚未被 LS-151 刪除的 `auth.uid()` 直接
插入一列全新的 `profiles`（`deletion_requested_at` 預設 `NULL`）——帳號看起來
「復活」了，「已請求刪除」這個事實整個消失。Tombstone 讓列繼續存在，這句 upsert
改走「已存在，整句不執行任何寫入」分支，帳號復活的路徑從根本上不成立（
`deletion_requested_at`／`purged_at` 也本來就沒有對 `authenticated` 開放
`UPDATE`，client 這句話連想動都動不了這兩欄）。真正的實體清除交給 LS-151：
`auth.users` 被 `delete-account` Edge Function 刪除時，`profiles.id references
auth.users(id) on delete cascade` 會讓 tombstone 列一起消失。

**依賴 LS-151 的安全性論證（R3，F5-informational i5）**：本票只確保
`deletion_requested_at` 已設定的使用者「重新登入不會讓帳號復活」；但如果
`delete_my_account()`（LS-143）之後、`purge_expired()` 30 天清除之前，這個人又
成為某個家庭的活躍成員（例如又被邀請加入），本票的 tombstone 機制本身**不會**
阻止這件事——真正從源頭排除「已請求刪除的使用者還能繼續正常使用 app」這個狀態
的是 LS-151 的 `LS051` `before insert` guard（讀 `profiles.deletion_requested_at`
擋七張表的寫入）。也就是說，本票 tombstone 的安全性論證有一部分**依賴 LS-151
落地**，不是本票自己完整涵蓋——若 LS-151 尚未部署，這個邊界情境仍然存在（風險
等級與 R1 review 原本點名的「purge 撞 LS001 永久靜默」同一類，已由 F2 的
tombstone 修法結構性排除主要路徑，這裡記錄的是次要、依賴外部票的殘餘依賴）。

Tombstone 時一併硬刪這個人的 `reactions`／`device_tokens`／
`join_requests`（`applicant_id`）／`blocked_users`（雙向）——這四張表原本靠硬刪
`profiles` 的 FK cascade 自動清掉，改成 tombstone 之後 cascade 不會觸發，改用
明確 `DELETE`（`device_tokens` 尤其實質重要：「已刪除」的帳號不該還收得到推播）。
**刻意不動 `family_members`**：`delete_my_account()` 呼叫成功之後，
`family_members` 對這個 uid 本來就該是 0 列（情況 2 隨家庭 cascade 掉、情況 3
在 RPC 呼叫當下同步 `DELETE`），這裡若還手動對它下 `DELETE`，萬一哪天真的因為
非預期 bug 讓某個 uid 仍留著 `family_members` 列且剛好是僅存的 owner，會觸發
既有的 `enforce_family_has_owner()` trigger 噴 `LS001`，把整個 `profiles` 區塊
每天卡住重試、每天失敗——不觸碰它從結構上排除這個風險，`family_members` 的
正確性交給 `delete_my_account()` 自己的既有測試覆蓋。**R2 起 `diaries`／
`albums`／`comments` 的 `author_id`／`created_by`／`uploaded_by`／`deleted_by`、
`content_reports.reporter_id` 等欄位不再被 set null**——`profiles` 列還在（只是
PII 已清空），FK 完整指向那個 tombstone 列，讀取端會看到作者顯示名稱是「已刪除
的帳號」，而不是一個解不開的 `NULL`。

**執行機制**：`pg_cron` 每日一次（`0 19 * * *`，UTC，≈台北時間凌晨 3 點）呼叫
`private.purge_expired()`；Storage 物件的實際刪除由 Edge Function
`supabase/functions/purge-storage`（`service_role`）消化 `public.purge_storage_queue`
——依 `enqueued_at` 排序讀取待刪列（分批＋迴圈直到清空或達安全上限，R2 修正：R1
版本只讀一批 200 筆、沒有排序，佇列超過一批會卡住後段）、呼叫 Storage Admin API
刪除物件、**逐路徑核對回傳的 `data` 陣列，只有真的確認被移除的路徑才 `DELETE`
該筆佇列列**（R2 修正：R1 版本把「呼叫沒有 `error`」直接當「整批都處理完成」，
本機實測對一個不存在的 bucket 呼叫 `remove()` 一樣回傳 `error: null`、`data: []`，
會把完全沒真的刪除任何東西的批次誤判成功而永久遺失佇列紀錄；改法逐路徑比對
`data[].name`，未確認的路徑留在佇列下次重試，純佇列語意不變，沒有處理狀態欄）。

**呼叫方式（LS-196 訂正鑑權機制）**：這支函式只接受 service 憑證，不是給
app client 呼叫的公開端點。原本（LS-153 落地時）用 Supabase 平台層
`verify_jwt`（預設開啟）＋程式內比對 `Authorization: Bearer` 等於
`SUPABASE_SERVICE_ROLE_KEY` 本身——但正式站接排程煙測（LS-153 i4，comment
`0535eab8`）發現這條守門對任何呼叫者都是 `401`：正式站
`supabase secrets list` 回報的 `SUPABASE_SERVICE_ROLE_KEY` sha256 digest
不等於 CLI／Management API 回報的 legacy service_role JWT——專案已建新式
`sb_secret_` default key，Edge Function 執行期注入的 `SUPABASE_SERVICE_ROLE_KEY`
從一開始就不是那把 legacy JWT。LS-196 訂正：`supabase/config.toml` 加
`[functions.purge-storage] verify_jwt = false`（關掉平台層 JWT 驗證），改用
`supabase/functions/_shared/keys.ts` 的 `isAuthorizedServiceCall()` 在程式內
驗——`apikey` header 等於任一 `SUPABASE_SECRET_KEYS` 值（新式 key），或（過渡，
直到所有呼叫端都已改用新式 key 為止）`Authorization: Bearer` 等於
`SUPABASE_SERVICE_ROLE_KEY`（legacy）。admin client 用
`resolveSecretKey()`（優先新式 default、缺則退回 legacy）建立。

`pg_cron`＋`pg_net` 呼叫範本（正式站排程接線時使用，`apikey` 從 `vault` 讀取、
不寫死在 SQL 裡）：`ls153_purge_storage_secret_key` 是**本票新建**的 vault
secret（存新式 `sb_secret_…` default key），與 LS-153 既有的
`ls153_purge_storage_service_role`（存 legacy service_role JWT，LS-153 comment
`0535eab8` 建立）**並存，不是沿用同一個 secret 改內容**——切換 cron job 標頭
前務必先確認 `ls153_purge_storage_secret_key` 已建立（`select 1 from
vault.decrypted_secrets where name = 'ls153_purge_storage_secret_key'`），
否則子查詢回 `NULL`、`jsonb_build_object('apikey', NULL)` 產出
`{"apikey": null}`，症狀與本票要修的 401 一模一樣。舊的
`ls153_purge_storage_service_role` 待 cron job 切換完成、煙測通過後再刪除：
```sql
select net.http_post(
  url := '<SUPABASE_URL>/functions/v1/purge-storage',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'apikey', (
      select decrypted_secret from vault.decrypted_secrets
      where name = 'ls153_purge_storage_secret_key'
    )
  )
);
```

**毒丸隊頭阻塞與死信／退避（R3，merge-review R2 F1 major，comment 7420f7b9）**：
R2 版本「無法確認已刪的列永遠留在佇列、下次重試」沒有出口——這些列的
`enqueued_at` 不會變，`order by enqueued_at limit BATCH_SIZE` 每次都只讀得到
它們，佇列滿一批（200 筆）無法確認的列之後，後面任何列都再也讀不到，且原本的
迴圈中止條件（「整批確認完成才繼續」）在有這種列時會讓迴圈退化回單批（e2e 實測
重現：200 筆「物件已不存在」的舊列擋住 2 筆真實物件，`processed` 永遠是 0，見票
handoff 附的 e2e 輸出）。R3 採 reviewer 建議的兩個修法並用：
1. `purge_storage_queue` 新增 `attempts`／`last_error`／`next_attempt_at` 三欄；
   remove() 呼叫本身出錯，或呼叫 `getBucket()` 確認不到 bucket 存在時，透過
   `public.purge_storage_queue_mark_failed()`（`service_role`-only、`security
   definer`）記一次失敗：`attempts` 遞增、依指數退避（`2^attempts` 分鐘）設定
   `next_attempt_at`；達 5 次視為死信，`select` 端的 `where attempts < 5` 之後
   不會再選到它（停放，仍保留列供稽核，不再佔住隊頭）。**退避上限（R4，
   merge-review R3 minor 3，文字修正、不動行為）**：公式裡 `least(attempts + 1,
   10)` 把指數壓在 10，理論上限是 `2^10 = 1024` 分鐘（約 17.07 小時），不是
   之前文件誤寫的 24 小時；而且因為 `MAX_ATTEMPTS=5` 就會被死信條件排除，
   **實際能觀察到的最大退避是 32 分鐘**（`2^5`），1024 分鐘那個理論上限永遠
   用不到。
2. remove() 呼叫沒有出錯、但某些路徑沒有出現在回傳的 `data[]` 裡時，額外呼叫
   一次 `getBucket()` 確認 bucket 本身存在——如果 bucket 存在，「路徑沒出現在
   `data[]` 裡」語意上就是「物件已經不存在」（不論是這次呼叫就發現、還是上一次
   已經真的刪除但 `.delete().in("id", doneIds)` 失敗留下的殘影，兩者的目的都已
   達成），可以立刻安全 dequeue，不需要等到 `attempts` 用盡；如果 bucket 不存在
   （R1 F5 的洞），才落入 1. 的 `attempts`／退避／死信路徑。**這代表「物件真的
   已經不存在」會立刻自我修復（同一次 invocation 內就 dequeue，e2e 實測：200 筆
   毒丸＋2 筆真實物件混合，修後單次呼叫 `processed=202`），只有「環境本身有問題」
   （bucket 打不到／remove() 呼叫出錯）才會真的累積 `attempts`、最終死信停放**
   （e2e 實測：對一個不存在的 bucket 連續呼叫 5 次，`attempts` 依序遞增為
   1／2／3／4／5，`next_attempt_at` 退避間隔依序是 2／4／8／16 分鐘（`2^attempts`
   分鐘），第 6 次呼叫起被死信條件（`attempts < 5`）排除、`processed=0`
   `failed=0`——見票 handoff）。迴圈不再因為單一批次有任何一筆未確認就中止：
   只要還沒到達安全上限、且這一輪的 `select` 仍讀得到列，就繼續下一輪；`select`
   端的 `attempts`／`next_attempt_at` 篩選條件本身就會讓「這一輪已標記失敗、進入
   退避」的列在同一次 invocation 內不會被重複讀到。

**死信的觀測出口（R4，merge-review R3 minor 2）**：死信停放本身是 F1 修法要的
效果，但 R3 review 指出停放之後**沒有任何地方看得到**——EF 回應永遠是
`{"processed":0,"failed":0}` HTTP 200，跟「佇列本來就空」看起來一樣。R4 最小
改動：EF 回應 JSON 加一個 `parked` 欄位（這次 invocation 結束時，`attempts >=
5` 的停放列總數），並 `console.log` 一行同樣的數字（Edge Function 的 log 由
Supabase 平台保留，供之後真的接上排程與 log 監看時使用）。**巡檢 SQL**（orchestrator
接 i4 的排程時一併接進巡檢，見下段「執行機制」）：
```sql
select count(*) from public.purge_storage_queue where attempts >= 5;
```
非零代表有 Storage 物件正卡在死信、需要人工介入（查 `last_error` 判斷是 bucket
設定錯誤還是其他環境問題）。刻意不擴充 `private.purge_runs`（那張表記的是
`purge_expired()` 的 DB 端結果，EF 是完全獨立的 invocation，混進同一張表的
schema 會讓兩件事的觀測耦合在一起，不是這裡要解的問題）。

`public.purge_storage_queue` 啟用 RLS、無 policy、只 `grant select, delete` 給
`service_role`（`authenticated`／`anon` 兩層皆擋，同 `notification_events` 既有
模式）；`attempts`／`last_error`／`next_attempt_at` 的寫入不直接開 `UPDATE` 給
`service_role`，只能透過 `purge_storage_queue_mark_failed()` 這支 definer 函式
（見 migration 第 2b 段）。**已驗證（R2＋R3）**：這支 Edge Function 已用本機
`supabase functions serve --no-verify-jwt`（經 `scripts/ops/supabase-lock.sh`）
做過端對端手動驗證，含 R3 的毒丸隊頭阻塞回歸（修前／修後對照）與死信／退避 6 次
連續呼叫的完整驗證（見上段、票 handoff 附完整輸出）；但**沒有**寫成
`supabase/tests/` 底下可重複執行的自動化測試（這個 repo 目前沒有任何
Deno/Edge Function 的測試治具，e2e 驗證腳本留在票的 handoff／scratchpad 供之後
建置治具參考）。`private.purge_expired()` 本身、`purge_storage_queue` 佇列內容
（含 `purge_storage_queue_mark_failed()` 的 SQL 面：`attempts`／`last_error`／
`next_attempt_at`、死信條件）、`profiles` tombstone、孤兒／第二層孤兒
`comments`／`reactions`／`content_reports` 清除則完全由
`supabase/tests/101_purge_expired.sql` 覆蓋（29／30／31 天邊界——含 `profiles`
自己的邊界，R3 F4 補上——跨家庭隔離、額度對帳、冪等重跑、與 `set_child_deleted`
還原的併發正確性），另有 `supabase/tests/concurrency/purge_vs_restore_child_*`
覆蓋 purge 硬刪孩子檔案與 owner 還原同一個孩子的併發正確性。`pg_cron` 排程本身是
**fail-soft**：本機開發映像若沒有 `shared_preload_libraries` 載入 `pg_cron`，
`CREATE EXTENSION` 會直接失敗，migration 把這個情況吞掉只留 NOTICE，不擋
migration chain（本機開發映像實測 pg_cron 1.6.4 可用）；正式站部署（`db push`＋
Edge Function 部署＋排程確認）依 LS-78 授權狀態由 orchestrator 處理，不在本票
範圍。**目前沒有任何東西會觸發這支 Edge Function**（無 `pg_cron`、無 Scheduled
Function 註冊——`pg_cron` 只排了 `purge_expired()`，見上方 migration 第 6 段）：
正式站需要另外接排程（`pg_cron`＋`pg_net`，或 Supabase 原生的 Scheduled Edge
Function），由 orchestrator 依 LS-78 部署狀態決定時機與方式，不在本票落地範圍
——EF 觸發機制沒接上之前，Storage 物件端對端實際上一個都不會被刪，這是
LS-132 對外文字上線前的硬前置（R2 review informational i4）。

**索引建立方式（R3，F5-informational (b)）**：本 migration 六張 partial index
（見「0. 效能索引」）用 `create index`（非 `concurrently`）——migration 在單一
交易內執行，Postgres 的 `create index concurrently` 不能在交易區塊裡跑，兩者
互斥，這支 migration 沒有拆成多支交易的必要（**不修＋理由**：這些表目前資料量
極小或全新建立，短暫的寫入鎖對 TestFlight 前的正式站沒有實質影響；若未來要在
已有大量資料的正式站補類似索引，屆時應該另開一支不在交易內執行的 migration，
不是回頭改本票）。

**觀測**：每次執行在 `private.purge_runs`（`private` schema，不經 PostgREST）留一列
（執行時間、六張表各自清除筆數——`comments`／`reactions` 是累加值——Storage 佇列
筆數、失敗表數與原因）；每張表的清除各自獨立錯誤處理，一張表失敗不影響其他表照常
清除，WHERE 條件冪等，失敗的表下次排程自然重試，不需要額外的重試佇列。

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

## 8. 多寶貝標記（children 多對多，LS-121）

- `children.family_id` → `families.id`：**一個 family 可以有多個 children**（1:N），
  PLAN §1「同時看自己家和妹妹家的小孩」是跨 family 的情境，這裡講的是同一個 family
  內可以登記多個孩子（例如雙胞胎、或大寶二寶）。
- **一篇日記／一本相簿可以標 0～N 個孩子**（多對多，LS-121 起，取代 LS-47 之前
  「發佈單選歸屬、可不指定」的定案第⑤題——LS-119 核可頁回饋第 8 點推翻：「不指定」
  仍保留、「指定」可多個）。透過 `diary_children (family_id, diary_id, child_id)` /
  `album_children (family_id, album_id, child_id)` 兩張連結表表達，取代舊版
  `diaries.child_id` / `albums.child_id` 單一欄位（已移除）。複合外鍵綁定同一家庭
  （`(family_id, child_id) → children(family_id, id)`），確保不會掛到別家的孩子；
  跨家庭一律 `23503`。沒有標記＝家庭共用內容，跟舊版 `child_id IS NULL` 同義。
- 沒有任何約束限制「同一個孩子只能有一個相簿／一篇日記」，或「一篇內容只能標一個
  孩子」——兩張連結表都沒有額外的 UNIQUE，`(diary_id, child_id)` / `(album_id,
  child_id)` 本身是複合主鍵，一個孩子可以出現在任意多篇內容裡，一篇內容也可以標
  任意多個孩子。
- `media` 本身**不**直接關聯任何孩子——照片只透過 `album_media`/`diary_media` 間接
  掛在有孩子標記的相簿／日記底下。要查「某個孩子的所有照片」，正確路徑是先查
  `album_children`/`diary_children` where `child_id = ?` 拿到 `album_id`/`diary_id`，
  再 join `album_media`/`diary_media` 取 `media`，**不是**在 `media` 表上直接篩選
  （那個欄位不存在）。
- **建立與標記是兩個步驟**：`create_diary_entry` 的 `p_child_ids` 參數讓「建立」與
  「標記」在同一次 RPC 呼叫內完成；`albums` 本體仍是建立者直接 `.insert()`（未變，
  見 §3），標記孩子是緊接著的第二步，呼叫 `set_album_children`（見 §4）。
- **寫入語意（`create_diary_entry`／`update_diary_entry`／`set_album_children`
  三支 RPC 共用）**：`p_child_ids` 為 `NULL` 或空陣列＝不指定／清空；非空時全覆蓋
  （`update_diary_entry`／`set_album_children` 是刪多補少，不是逐一新增／移除；
  `create_diary_entry` 是全新建立，沒有「舊集合」可比較）；陣列裡的 `NULL` 元素與
  重複值靜默過濾／去重；任一元素跨家庭 `23503`；任一元素指向已軟刪的孩子 `LS044`
  （見下）。
- **時間軸的多寶貝篩選**（`get_family_timeline` 的 `p_child_id` 參數，見 §4）——
  LS-48 當時是「全部／單寶貝」兩種篩選，LS-121 起維持同一個參數形狀（仍是單一
  `p_child_id`，不是陣列；一次篩一個孩子），但底層資料模型已經是多對多：
  - `p_child_id = NULL`：回傳全部（不篩），一篇同時標了 2 個孩子的日記／相簿**只
    出現一次**——這條查詢走 `feed_items` 本身，一個項目一列，天然不重複。
  - `p_child_id = <某個孩子>`：只回傳標記含這個孩子的項目；同一篇同時標了 2 個
    孩子的內容，用其中任一個孩子篩選都會**各自出現一次**（分別是兩次不同的查詢，
    不是同一次查詢回傳兩列）。**`media` 類項目一律不出現**——`media` 沒有直接的
    孩子標記可比對，見上一條。
  - 兩種情況下，回傳列的 `child_ids` 都是該項目標記的**全部**孩子（不只是篩選
    命中的那一個），見 §4 `get_family_timeline` 的回傳說明。
  - **設計取捨（EXPLAIN 證據見 PR handoff）**：`p_child_id` 篩選走一張獨立、由
    trigger 維護的扁平表 `feed_item_children (family_id, kind, ref_id, child_id,
    occurred_at)`，而不是查詢時 join `diary_children`/`album_children`——理由是
    LS-48 F1 的教訓（join 之後再依 keyset 排序分頁，規劃器很難把排序下推成走
    複合索引；「全部」若不小心 join 進連結表還會產生重複列，需要額外 DISTINCT，
    在 keyset 分頁下容易跳項或重複）。細節見
    `supabase/migrations/20260902011514_diary_album_multi_child_tags.sql` 第 0 段。
  - **keyset 分頁不跳項**：`feed_item_children` 對每個 `(kind, ref_id)` 依標記的
    孩子各自有一列，索引 `feed_item_children_family_child_occurred_idx (family_id,
    child_id, occurred_at desc, ref_id desc)` 與 `feed_items` 本身的排序鍵完全
    一致，游標語意相同，見 `supabase/tests/97_multi_child_tags.sql` 的灌量測試。
- **軟刪孩子與時間軸／照片日記的關係（LS-66；LS-47 定案第④題；LS-121 延伸到連結表）**：
  軟刪一個孩子（`set_child_deleted`）對**既有**標記完全不連動——`diary_children`／
  `album_children`／`feed_item_children` 裡既有的列不會被這支 RPC 動到（它只改
  `children` 這一張表的 `deleted_at`／`deleted_by` 兩欄）。因此：
  - `get_family_timeline` 對一個已軟刪孩子的行為**完全不變**——`p_child_id` 傳這個
    孩子的 id 一樣正常回傳他標記過的日記／相簿項目；`p_child_id` 為 `NULL`（查全部）
    時，這些項目原本就會出現，軟刪前後沒有差異。
  - **呼叫端契約：時間軸上的 `child_ids` 一律可解析**——`get_family_timeline`
    回傳的任何 `child_ids` 元素，呼叫端都保證可以用 `list_children` 或直接
    `.from("children").select()` 查到對應的孩子（含名字／`deleted_at` 旗標），不論
    呼叫者是哪個角色、也不論那個孩子是否已被軟刪——`list_children` 與 `children_select`
    對所有角色回傳全部列（見 §3「軟刪旗標的可見性」），不會出現「時間軸上有一則
    內容標了某個孩子，但這個角色查這個 id 查無此人」的斷裂。
  - **已軟刪的孩子不能再被指定為新內容的標記**（`LS044`，見 §3／§5）——這條規則
    管的是「未來要不要允許新標記」，跟上面「過去已經標記的內容繼續保留、繼續可查」
    是互補而非矛盾：舊帳不翻、新帳不開。守門搬到連結表的 `BEFORE INSERT` trigger
    （`private.enforce_child_not_deleted()`，函式本身沿用 LS-66 定義，未改寫，只是
    改掛到新表上）——只在真的要 INSERT 一列新標記時才檢查，既有標記（不論指向的
    孩子後來是否被軟刪）完全不受影響，掛在已軟刪孩子底下的既有日記／相簿依然能
    正常編輯內容、軟刪／還原自己。**已知限制（沿用 LS-66 R2 I7 的既有裁量，不重複
    展開）**：這支 trigger 讀 `children` 時不取鎖，存在毫秒級 TOCTOU 窗口，見
    migration 對 `private.enforce_child_not_deleted()` 的裁量說明。
  - 30 天還原邊界只作用在 `children` 這張表本身（`set_child_deleted` 的 `LS043`），
    不影響任何時間軸／照片／日記的可讀性——即使一個孩子已軟刪超過 30 天、事實上
    再也無法還原，他名下標記過的日記與相簿依然完整保留、依然可查（本票不含刪除
    策略，只有 `deleted_at` 語意，見 §3）。
- **刪除孩子時連結表的級聯**：`diary_children`／`album_children`／
  `feed_item_children` 對 `(family_id, child_id)` 的複合外鍵是 `on delete cascade`
  （不是舊版 `feed_items.child_id` 用過的 `on delete set null`——那個欄位已隨本票
  移除）。本票仍然沒有任何應用層的孩子硬刪路徑（`children_delete` policy 依舊全擋，
  見 §3 `children` 段），這條 CASCADE 目前只在假設性的「未來若開放硬刪」情境下才會
  真的觸發，回歸測試見 `supabase/tests/85_diaries_timeline.sql` §7。

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
accept_eula(text)
approve_join(uuid)
block_user(uuid, uuid)
claim_notification_events(integer)
create_child(uuid, text, date, text)
create_comment(uuid, text, uuid, text)
create_diary_entry(uuid, uuid[], text, date)
create_invite(uuid, text, timestamptz, integer)
delete_my_account()
finalize_account_deletion(uuid)
get_family_quota(uuid)
get_family_timeline(uuid, uuid, timestamptz, uuid, integer)
get_my_join_request()
get_reaction_counts(uuid, text, uuid[])
list_children(uuid)
list_comments(uuid, text, uuid, timestamptz, uuid, integer)
list_join_requests()
notification_recipients(uuid[])
purge_storage_queue_mark_failed(uuid[], text)
register_device_token(text, text)
reject_join(uuid)
remove_content_as_owner(text, uuid)
report_content(uuid, text, uuid, text)
request_join(text)
set_album_children(uuid, uuid[])
set_album_deleted(uuid, boolean)
set_child_deleted(uuid, boolean)
set_comment_deleted(uuid, boolean)
set_diary_deleted(uuid, boolean)
toggle_reaction(uuid, text, uuid)
unblock_user(uuid, uuid)
update_child(uuid, text, date, text)
update_comment(uuid, text)
update_diary_entry(uuid, text, date, uuid[])
withdraw_join(uuid)
-->

<!-- API-CONTRACT:TABLES
album_children
album_media
albums
app_settings
blocked_users
children
comments
content_reports
device_tokens
diaries
diary_children
diary_media
families
family_members
feed_item_children
feed_items
invites
join_requests
media
notification_events
profiles
purge_storage_queue
reactions
-->

---

## 10. Edge Functions

`supabase/functions/*` 不是 PostgREST 契約（不在上面 §9 的機械對帳範圍內——那份清單
只認 `public` schema 的 RPC／表），是獨立部署的 Deno 服務，用 `Deno.serve` 監聽單一
HTTP 端點。這裡记錄呼叫端（iOS）需要知道的契約；函式本體的實作細節見各自的
`index.ts` 檔頭註解。

### `delete-account`（LS-151）

- **路徑**：`POST {SUPABASE_URL}/functions/v1/delete-account`。其他 HTTP method
  一律 `405`（R2 minor-1；GET 具破壞性，且與這裡寫的「路徑」不符，不該一視同仁地
  執行刪除）。
- **鑑權**：Supabase 平台層 `verify_jwt`（`supabase/config.toml` 沒有針對本函式覆寫，
  預設開啟）先擋掉沒有合法簽章 JWT 的請求；函式內部再用該 JWT（`Authorization: Bearer
  <使用者的 access token>`——**不是** anon key、**不是** service_role key）呼叫
  `auth.getUser()` 換回呼叫者的 `uid`。這一步同時是「確認呼叫者這個帳號現在還真的
  存在」的檢查——見下方「冪等語意」。
- **呼叫順序（client 端硬性規定，docs 已在 §4 `delete_my_account` 重申）**：`
  delete_my_account()` RPC 回傳成功後**立即**呼叫本端點，中間不得允許使用者做任何
  操作。RPC 只標記 `profiles.deletion_requested_at`，本端點才是真正刪除
  `auth.users` 的那一步；沒有呼叫本端點，帳號不會被刪除（也不會有排程自動補做——
  30 天後的 `private.purge_expired()`，LS-153，是資料面 30 天沒清乾淨時的最後防線，
  不是這支 Edge Function 的替代品，見該 migration §「自動清除」）。
- **處理流程**（R3 訂正順序，merge-review R2 N5）：
  1. 非 `POST` → `405`。
  2. 驗證 `Authorization` header 存在且 `auth.getUser()` 能換回合法使用者，否則
     `401`。
  3. 以 `service_role` 讀 `public.profiles.deletion_requested_at`（見 §3
     `profiles`）：`NULL` 或找不到這個 `profiles` 列一律 `400`——**這是刻意的守門，
     不是遺漏**：沒有走過 `delete_my_account()` RPC 的人不能直接打這支端點刪掉
     自己的帳號（繞過 RPC 的唯一 owner 守門、`LS050` 轉移檢查等資料面安全檢查）。
  4.（**第一道防線**，merge-review R1 B1／M1）以 `service_role` 呼叫
     `public.finalize_account_deletion(p_user)`（只授權 `service_role` 執行的
     SECURITY DEFINER RPC，見下方「`finalize_account_deletion`」段落）——刪除
     `auth.users` 前重跑一次資料面清理。**排在撤銷之前**（R3 N5）：撤銷是不可逆
     的第三方動作，finalize 卻可能因暫時性競態失敗（見下方「N1：40P01 重試
     契約」），不該讓不可逆動作搶在可能失敗的步驟之前執行。失敗 → `500`（一般
     失敗）或 `503`（已知的暫時性競態，見下方契約）；兩種情況都 fail loud，
     **不**繼續往下走撤銷／刪除。原始錯誤只進 `console.error`（R3 N2），回應
     body 一律固定文案 `{"error": "deletion_failed", "stage": "finalize"}`
     （或 503 時 `{"error": "deletion_temporarily_unavailable", "stage":
     "finalize"}`）——不外洩資料庫內部訊息（可能含其他家庭的 UUID）。
  5. 撤銷步驟（見下方「Apple／Google token 撤銷」）：best-effort、平行送出
     （`Promise.all`，R2 minor-2），任何失敗或 env／token 缺失都只記錄，**不會**
     讓整個請求失敗——帳號刪除是強制性的產品／法遵要求，第三方撤銷是盡力而為的
     附加動作，優先序不對等。每次呼叫記一行 `console.log`（user id ＋結果碼，
     不含 token／key／email，R2 minor-4——LS-132 隱私政策 §8 的撤銷承諾要能舉證）。
  6. 呼叫 GoTrue admin API `deleteUser(uid)`（同樣記一行 `console.log`，R2
     minor-4）。成功 → `200`（`profiles` 隨 `on delete cascade` 一併消失，見 §3
     `profiles`）。GoTrue 回報「使用者不存在」→ 視為已達成目的，`200`（見下方
     「冪等語意」）。其他失敗 → `500`（body 同上固定文案，`stage: "auth_delete"`，
     原始錯誤只進 `console.error`，R3 N2）。
- **`finalize_account_deletion(p_user uuid)`**（R2，`20260903115014_delete_account_edge_support.sql`）：
  只授權 `service_role` 執行的 SECURITY DEFINER RPC（`authenticated`／`anon`／
  `PUBLIC` 皆無 `EXECUTE`，見 `supabase/tests/60_default_privileges.sql` 白名單）。
  只在 `p_user` 的 `deletion_requested_at` 非 `NULL` 時才會執行，否則 `raise`
  （防誤呼叫刪除健康帳號的家庭關係）。語意：刪除 `p_user` 尚未處理的 pending
  `join_requests`；逐一處理 `p_user` 所屬的每個家庭——非唯一 owner 直接刪其
  `family_members` 列；唯一 owner 且家庭還有其他成員，把最早加入（`created_at`
  升冪）的其他成員升為 owner 後再刪自己那一列；唯一 owner 且沒有其他成員，整個
  家庭連同底下資料一併刪除（cascade）。全程對相關 `family_members`／`families`
  列 `FOR UPDATE` 鎖住（刻意不是 `FOR NO KEY UPDATE`——要與子表 INSERT 的 FK 檢查
  取的 `FOR KEY SHARE` 互斥，關閉 M1 指出的「標記與並行 INSERT」競態窗口）。這是
  「刪除一定成功」唯一不依賴「過渡期擋寫沒有漏洞」的防線——見下方「過渡期擋寫」
  與 migration 檔頭「R2」段落的完整訂正紀錄。
  - **N1：40P01 重試契約**（merge-review R2，R3 訂正）：取鎖順序**先
    `family_members` 後 `families`**，對齊既有 `private.enforce_family_has_owner()`
    的鎖序（DML 先自然鎖住它正在改的 `family_members` 列，AFTER STATEMENT trigger
    才對 `families` 取 `FOR NO KEY UPDATE`）——R2 版本鎖序相反，reviewer 雙連線
    實測到 `40P01 deadlock detected`（同家庭有另一位成員的角色／`can_upload`
    異動同時發生時）。R3 訂正後仍有一般性的鎖等待窗口（不是死鎖，Postgres 不需要
    自動偵測介入），且極端情況下仍可能與其他路徑撞出新的死鎖形狀——**EF 對
    `40P01` 自動重試一次**（`index.ts` 的 `finalizeAccountDeletion`）：Postgres
    偵測死鎖後自動回滾其中一邊、無資料損毀，重試幾乎必定收斂（`finalize_account_deletion`
    本身冪等、守門仍成立）。若重試後仍是 `40P01`，Edge Function 回 `503`
    （`deletion_temporarily_unavailable`）而不是泛用的 `500`——呼叫端收到 `503`
    可安全地整個重新呼叫本端點一次（不需要退避等待，Postgres 的死鎖偵測是
    毫秒級的，衝突視窗極窄）。
- **過渡期擋寫（第二道防線，縱深防禦）**：`deletion_requested_at` 非 `NULL` 時，
  `families`／`media`／`diaries`／`albums`／`children`／`comments`／
  `join_requests` 的 `INSERT` 與 `family_members` 的 `INSERT`／
  `UPDATE OF role, user_id` 一律拒絕（`LS051`）。`family_members`／
  `join_requests` 的 guard 查的是**被寫入的人**（`NEW.user_id`／
  `NEW.applicant_id`），不是操作者的 `auth.uid()`——這是 R2 對 merge-review R1
  B1 的訂正：R1 版本查 `auth.uid()`，擋不住「健康的 owner 核准一個過渡期申請人」
  或「健康的 owner 把過渡期成員升成 owner」這兩條路（見 migration 檔頭）。
- **冪等語意**：正常情況下呼叫端只會呼叫一次；若因網路重試等原因重複呼叫：
  - 第一次呼叫已成功刪除 `auth.users` 之後的重複呼叫，帶的是同一把 JWT——這把 JWT
    在簽章／效期上可能仍然合法，但第 1 步的 `auth.getUser()` 會因為對應的使用者
    在 GoTrue 裡已經不存在而失敗，回應 `401`（明確的 4xx，不是 `500`；呼叫端不需要
    也不應該把這個 `401` 當成「刪除失敗」重試，帳號其實已經刪除完成）。
  - 若因為某種原因 `auth.getUser()` 仍能換回使用者（例如刪除卡在 GoTrue admin API
    呼叫失敗、`profiles` 已標記但 `auth.users` 還在），第 4 步的 `deleteUser` 再次
    呼叫是安全的——GoTrue 的刪除本身是冪等操作，回應 `200`。
  - 兩種情況都不會是「靜默什麼都沒發生的 2xx」或未分類的例外，呼叫端可以直接用
    狀態碼判斷是否需要提示使用者重試。
- **錯誤回應格式**（R3 訂正，merge-review R2 N2）：`400`／`401`／`405` 三種前置
  條件失敗回 `{"error": "<簡短訊息>"}`（不含使用者資料，本來就安全）；`500`／
  `503`（finalize 或 deleteAuthUser 的實際失敗）一律回固定文案
  `{"error": "deletion_failed" | "deletion_temporarily_unavailable", "stage":
  "finalize" | "auth_delete"}`——**不含原始錯誤訊息**：GoTrue／Postgres 的原始
  錯誤可能夾帶其他家庭的 UUID 或內部 SQL 片段（merge-review R2 N1 死鎖情境下的
  實測例子），這是隱私優先產品，HTTP 回應不該外洩資料庫內部細節；原始錯誤只進
  `console.error`（伺服器端稽核用）。沒有使用 `LSnnn` 自訂碼（這支端點不經
  PostgREST，`LSnnn` 是 Postgres `SQLSTATE`，不適用於 Deno 端直接回傳的 HTTP
  錯誤）——呼叫端依 HTTP 狀態碼＋`stage` 分流：`400`＝前置條件不滿足、`401`＝
  JWT 無效或使用者已不存在、`405`＝method 錯誤、`500`＝伺服器端失敗（一般不建議
  自動重試）、`503`＝已知的暫時性競態（可安全立即重試整個請求一次，見上方
  「N1：40P01 重試契約」）。
- **Apple／Google token 撤銷**（LS-132 隱私政策 §8 承諾；LS-151 範圍）：
  - Apple：`POST https://appleid.apple.com/auth/revoke`，帶 `signal:
    AbortSignal.timeout(5000)`（R2 M2——Deno 的 `fetch` 預設沒有逾時上限，黑洞
    連線會讓 `deleteAuthUser()` 永遠不被呼叫，違反下面「不會因此擋下帳號刪除」
    的承諾；逾時後落進既有的 catch，跟其他 fetch 失敗一視同仁地當成
    best-effort 失敗）。需要 env `APPLE_CLIENT_ID`／`APPLE_CLIENT_SECRET`
    （兩者皆缺其一即跳過，**不會**因此擋下帳號刪除）與該使用者 Apple identity
    已存的 provider token（`auth.getUser`／`admin.getUserById` 回傳的
    `identities` 陣列裡找 `provider === 'apple'`）——**已知限制（如實揭露）**：
    本專案目前沒有在登入時保存 Apple 的 provider refresh token（Supabase 預設
    不落地存這個值，需要另外設計登入流程才能取得可撤銷的 token），因此這個
    分支在**目前**的資料下幾乎必定落在「找不到 token，跳過」——程式碼路徑與
    env 判斷都已到位、可單元測試（見
    `supabase/functions/delete-account/handler.test.ts`），但要讓這支撤銷真正
    發生效果，需要另開票在登入流程保存 Apple provider token，且真正打這支端點
    需要 LS-8（Apple Developer Program 付費帳號）到位後才能在真機驗證——本票
    未做真機驗證，見 handoff。撤銷結果（成功／失敗／略過）記一行
    `console.log`（R2 minor-4，user id ＋結果碼，不含 token／key／email）。
  - Google：`POST https://oauth2.googleapis.com/revoke`，同樣帶
    `signal: AbortSignal.timeout(5000)`（R2 M2），不需要 client secret
    （Google 的 token revoke 端點只吃 `token` 參數），一樣要求該使用者
    `auth.identities` 有 `provider === 'google'` 且找得到 provider token 才會
    真的呼叫；同樣**已知限制**：目前沒有保存 Google provider token，多半落在
    「找不到 token，跳過」，程式碼路徑可單元測試但未經真實 Google 帳號驗證。
  - Apple／Google 兩支撤銷平行送出（`Promise.all`，R2 minor-2），不互相等待。
- **本機測試**：`supabase/functions/delete-account/handler.test.ts`（Deno 內建
  `Deno.test`，注入 fake `fetch`／fake deps，不需要跑 `supabase functions serve`）
  ——`deno test`。若要跑完整整合測試（真的打本機 Supabase Auth／Storage），需要
  `bash scripts/ops/supabase-lock.sh -- supabase functions serve`（經 lock，容器
  共用），本票未建置這套治具（同 LS-153 `purge-storage` 的既有先例：本機開發環境
  沒有 Deno Edge Runtime 的整合測試環境），只有 Deno 單元測試＋人工 code review。
- **已知限制**：`index.ts` 的 `buildProdDeps()`——`auth.getUser()`／
  `admin.getUserById()`／`admin.deleteUser()`／`rpc("finalize_account_deletion")`
  的實際接線，以及 `deleteAuthUser` 冪等判斷式（`error.status === 404 ||
  /not.?found/i.test(...)`）——沒有單元測試覆蓋（R2 minor-9）。`handler.test.ts`
  的測試測的是「收到已算好的 `notFound`／`ok` 之後 `handleRequest` 怎麼做」，
  不是「怎麼算出這些值」；這段接線只能靠人工 code review 與（將來若建置）
  `supabase functions serve` 整合測試補上。
- **部署**（正式站，orchestrator 依 LS-78 授權狀態執行，不在本票落地範圍）：
  ```
  supabase functions deploy delete-account --project-ref mzkkkzbiejgvhwjyiokf
  ```
  另需在 Dashboard／CLI 設定 `APPLE_CLIENT_ID`／`APPLE_CLIENT_SECRET`（若要讓
  Apple 撤銷真的生效，且需搭配上述「保存 provider token」的後續票）；
  `SUPABASE_URL`／`SUPABASE_ANON_KEY`／`SUPABASE_SECRET_KEYS`／
  `SUPABASE_SERVICE_ROLE_KEY` 由 Supabase 平台在每個 Edge Function 執行環境
  自動注入，不需要另外設定（LS-196：admin client 改用 `resolveSecretKey()`
  解析出的金鑰；這支端點的使用者 JWT 驗證路徑與 `verify_jwt` 現狀不動）。

### `push-dispatch`（LS-172，LS-22 後端子票）

推播發送——消化 `notification_events` 待送佇列（§3；LS-58 資料面），彙總成一則則
長輩可讀的中文文案，呼叫 APNs。**只做後端**：不含 iOS 端 APNs 授權／
`register_device_token` 呼叫／通知設定 UI（LS-22 UI 子票）、不含 APNs 正式金鑰與
正式站部署（待 LS-8）、不含重試佇列／死信、不含 Email 摘要。

- **路徑**：`POST {SUPABASE_URL}/functions/v1/push-dispatch`。其他 HTTP method 一律
  `405`（同 `delete-account`／`purge-storage` 既有慣例）。
- **鑑權**：比照 `purge-storage`（不是 `delete-account` 的使用者 JWT 模式），
  這支端點設計給排程呼叫，不是給 app client 用的公開端點。**LS-196 訂正**：
  原本直接比對 `Authorization: Bearer <token>` 是否等於 `SUPABASE_SERVICE_ROLE_KEY`
  本身這條守門，與 `purge-storage` 同型地在正式站無法通過（`SUPABASE_SERVICE_ROLE_KEY`
  執行期注入值已非 legacy service_role JWT，見上方「呼叫方式」段與 §6
  `purge-storage` 的完整背景）——改用 `supabase/functions/_shared/keys.ts` 的
  `isAuthorizedServiceCall()`：`apikey` header 等於任一 `SUPABASE_SECRET_KEYS`
  值（新式 key），或（過渡）`Authorization: Bearer` 等於
  `SUPABASE_SERVICE_ROLE_KEY`（legacy）；`supabase/config.toml` 加
  `[functions.push-dispatch] verify_jwt = false`。**常數時間比對**：
  `_shared/keys.ts` 的 `timingSafeEqual()`（原本在 `handler.ts` 本機定義，
  LS-196 搬到共用 helper，purge-storage 同型）不論兩個字串是否等長、哪個位置
  先出現差異，都逐位元組跑完整輪比較才判斷，耗時只跟兩個字串的最大長度有關
  ——原本的 `!==` 是逐字元短路比較，理論上可被拿來做 timing attack 猜出正確的
  金鑰。
- **呼叫時機**：設計給排程（`pg_cron`＋`pg_net`，或 Supabase 原生 Scheduled Edge
  Function）定期呼叫。**本票只記載下方「排程（未建立）」的部署清單，不實際建立**
  ——同 `purge-storage`（LS-153）的既有先例，目前**沒有任何東西會觸發**這支函式，
  接排程由 orchestrator 依 LS-78 授權狀態後續處理。
- **處理流程**（R2 依 merge-reviewer m1 改成批次＋有上限併發＋時間預算，見下方
  「批次取件、併發送出與時間預算」段的完整取捨）：
  1. 非 `POST` → `405`。
  2. `SUPABASE_SECRET_KEYS`／`SUPABASE_SERVICE_ROLE_KEY` 皆未設定（部署設定
     缺失，`resolveSecretKey()` 解不出任何金鑰）→ `500`（fail loud，同既有 EF
     慣例；這兩個變數由 Supabase 平台自動注入，缺失代表部署本身有問題）。
  3. `apikey` 不等於任一 `SUPABASE_SECRET_KEYS` 值、且 `Authorization: Bearer`
     也不等於 `SUPABASE_SERVICE_ROLE_KEY`（`isAuthorizedServiceCall()` 判否）
     → `401`。
  4. 迴圈：**開始每一批之前**先檢查時間預算（見下方段落），預算將盡就停止（不再
     claim 新批次，`stopped_early: true`）；否則呼叫 `claim_notification_events()`
     （每輪 `p_limit=50`）取待送事件，直到回傳空批次或達安全上限
     `MAX_BATCHES=20`（20 × 50 = 1000 筆／次 invocation，比照 `purge-storage`
     的分段 dequeue 寫法）。
  5. 一次呼叫 `notification_recipients(p_event_ids)`（批次版，傳整批剛 claim 到的
     event id 陣列）取得這整批事件的對象＋其 device token 展開列，依 `event_id`
     分組，逐事件用下方「文案彙總矩陣」組出**一則**訊息（批次上傳只發一則彙總，
     不展開成多則——呼應 `docs/PLAN.md` 推播段「批次上傳 50 張照片要合併成一則」的
     取捨），展開成一份 token×文案的送出工作清單，用有上限的併發（預設 8）送出。
  6. APNs 回報 `410 Unregistered` 或 `400 BadDeviceToken` → 刪除該筆
     `device_tokens`（見下方「失效 token 處理」）。APNs 回報 `403
     ExpiredProviderToken` → 重簽 JWT 後重試一次（見下方 ApnsProvider 段）。其他
     錯誤只記 `console.log`，不重試、不刪 token。
  7. 回應（`200`，或部分失敗時仍 `200`——沒有部分成功／失敗的 HTTP 狀態碼區分，
     呼叫端看 body 裡的計數）：
     ```json
     {"claimed": 12, "recipients": 18, "sent": 16, "failed": 1, "tokens_removed": 1, "stopped_early": false}
     ```
     未預期例外 → `500`，body 固定文案 `{"error": "push_dispatch_failed"}`，原始
     錯誤只進 `console.error`（同 `delete-account` 既有慣例，不外洩資料庫內部訊息）。

- **`public.claim_notification_events(p_limit integer default 50) -> table(id uuid,
  family_id uuid, kind notification_kind, target_type content_target_type,
  target_id uuid, actor_id uuid, actor_display_name text, event_count integer,
  occurred_at timestamptz)`**（`20260904095205_push_dispatch.sql`）：
  service_role-only、`SECURITY DEFINER`。**票文字面寫的是 `private.
  claim_notification_events`，落地時改放 `public` schema**——這不是隨意偏離：
  `supabase/config.toml` 的 `[api] schemas = ["public", "graphql_public"]` 只把
  這兩個 schema 掛上 `/rest/v1/` 端點，`private` schema 完全不可見，Edge Function
  用 `supabase-js` 的 `.rpc()` 呼叫 `private.` 函式會直接拿到「函式不存在」；既有的
  `private.purge_expired()`／`private.record_notification_event()` 能留在
  `private`，是因為呼叫方分別是 `pg_cron`（直接 SQL）與同一交易內的 trigger，都不
  經過 PostgREST。授權邊界不靠 schema 名字，靠 GRANT／REVOKE（同
  `finalize_account_deletion`／`purge_storage_queue_mark_failed` 的既有形狀：
  `public` schema、但 `authenticated`／`anon` 皆無 `EXECUTE`，只有 `service_role`
  可執行，見 `supabase/tests/60_default_privileges.sql` §8 白名單）。
  - **語意（先 claim 再送，冪等鎖）**：`sent_at IS NULL AND occurred_at < now() -
    interval '5 minutes'`（5 分鐘滾動視窗已穩定，見 §3）才會被選中；同一句 SQL
    內用 `UPDATE ... FROM (SELECT ... FOR UPDATE SKIP LOCKED) ... RETURNING`
    標記 `sent_at = now()` 並回傳——`FOR UPDATE SKIP LOCKED` 保證多個並發呼叫互不
    重疊。**「漏送不重送」的取捨完整說明見 §3 `notification_events` 的
    `sent_at` 段**：這裡標記之後即使 `push-dispatch` 之後送出失敗，也不會回滾，
    寧可漏送不重送。
  - `actor_display_name` 已在 SQL 端 `COALESCE(display_name, '家人')` 算好——
    `actor_id` 為 `NULL`（觸發者帳號之後被硬刪，`notification_events.actor_id`
    的 FK 是 `on delete set null`）時 fallback「家人」；`profiles.display_name`
    依既有 schema 保證非空（見 §3 `profiles`），這個 fallback 只在 `actor_id`
    本身是 `NULL` 時才會用到。
  - `p_limit` 夾在 `[1, 500]`（`least(greatest(coalesce(p_limit, 50), 1), 500)`，
    同 `list_comments` 既有夾定慣例）。

- **`public.notification_recipients(p_event_ids uuid[]) -> table(event_id uuid,
  user_id uuid, token text, platform device_platform)`**（同一支 migration；
  **批次簽章（merge-reviewer LS-172 R2 m1）**——`push-dispatch` 一次要處理一整批
  claimed 事件，這支函式直接吃一批 `p_event_ids`、回傳列多帶 `event_id` 供呼叫端
  把收件人分回各自所屬的事件，不是逐事件各打一次（不必要的 round trip）。這支
  migration 檔在本 PR 落地前從未併入任何分支、也從未部署到任何環境，函式因此從
  一開始就直接定義成這個最終的批次形狀，不透過「先建單一事件版本、後續再
  `DROP FUNCTION` 改簽章」的兩階段寫法——那樣會被 `migration-breaking-check.sh`
  判成 DESTRUCTIVE（需要人工核可），但這支函式的簽章根本沒有任何外部依賴需要
  相容，兩階段寫法只是徒增一次不必要的核可步驟）：
  service_role-only、`SECURITY DEFINER`，同上理由放 `public` schema。回傳每個
  event_id 所屬家庭成員 × 其 `device_tokens` 的展開列（一人多裝置會有多列，
  `push-dispatch` 逐列即逐 token 發送），扣除：
  - **actor 本人**——自己觸發的事件不通知自己。
  - **封鎖了 actor 的成員**——`blocked_users` 是單向、限同家庭
    （`(family_id, blocker_id, blocked_id)`，見 §3「`content_reports` /
    `blocked_users`」）：`blocker_id = 該成員, blocked_id = actor_id, family_id =
    該事件的家庭` 存在即排除。
  - **沒有任何 `device_tokens` 的成員**——用 `JOIN`（非 `LEFT JOIN`）天生排除。
  - **`kind='report'` 時，只留 `family_members.role = 'owner'`**（LS-195，使用者
    2026-09-05 裁決「檢舉事件的推播通知只有 Owner」，銷 LS-96 池項
    `12e20e0c`）：其餘四種 kind（`comment`／`reaction`／`diary`／`album`／
    `media`）不受影響，仍廣播給全家庭成員（扣上述幾條既有排除條件）。這條規則
    跟 §10-B「檢舉內容本身只有 owner 讀得到」（`content_reports_select`
    policy）對齊——`notification_events` 這張表本身對 `authenticated` 沒有任何
    RLS policy 也沒有任何 table grant（見上方「`notification_events`」段），
    `claim_notification_events`／`notification_recipients` 兩支 RPC 也都只對
    `service_role` 開放 `EXECUTE`（無 `authenticated` grant），所以檢舉事件的
    列本來就不會透過任何既有讀取面外洩給非 owner 成員，本票不需要另外收緊
    RLS／grant。
  `actor_id` 為 `NULL` 時，「排除 actor 本人」與「排除封鎖 actor 的成員」這兩條
  規則天生都不會誤傷任何人（`NULL` 既不等於任何 `user_id`，也不會被任何
  `blocked_id` 條件命中）。`p_event_ids` 為 `NULL` 或空陣列、或某個 event_id
  不存在、或某個事件的 family_id 沒有任何符合條件的成員時，該 event_id 對應的
  列數就是 0（`= any('{}')`／`= any(NULL)` 天生不成立），不報錯（同
  `get_my_join_request()` 既有的「0 列＝空結果」慣例）。

- **批次取件、併發送出與時間預算（LS-172 R2，merge-reviewer m1）**：
  `handler.ts` 的 `runDispatch()` 迴圈——每一輪：批次 claim（`batchLimit=50`）
  → 一次批次呼叫 `notification_recipients()` 取整批對象 → 依 `deps.concurrency`
  （預設 8）有上限併發送出。
  - **時間預算與「不能已 claim 但沒送」這條不變量**：時間預算（`deps.
    timeBudgetMs`，`index.ts` 設 60 秒——**這是刻意保守的猜測值，不是任何
    Supabase／Deno Deploy 官方文件證實過的執行時間上限**，本票沒有查證到權威
    數字，選一個明顯遠低於典型 serverless 逾時的值當安全邊際）只在**開始下一批
    之前**檢查；一旦一批事件被 claim（`sent_at` 已標記），這批**一定會完整跑
    完**，不會半途中止——這是結構性保證，不是估算。時間預算耗盡時停止 claim
    新批次，回應帶 `stopped_early: true`。
  - **為什麼選這個設計、不是動態依剩餘時間縮小 claim 批次大小**：reviewer 原本的
    描述是「把 claim 的批次大小縮到時間預算內確定送得完」，字面上更接近「依剩餘
    時間動態估算下一批能 claim 幾筆」（自適應調整）。這裡選了更簡單的版本
    ——固定的保守批次大小＋批次間檢查——因為它已經用結構性保證（不是機率估算）
    滿足了 reviewer 真正在意的不變量，而自適應版本需要額外的校準邏輯（冷啟動沒有
    歷史數據可用）、複雜度明顯更高，換來的好處只是「單一批次的耗時更貼近預算」，
    對這個不變量本身沒有增益。
  - **殘餘風險與其在這個產品規模下可接受的理由**：固定批次大小沒有消除「單一批次
    本身耗時異常久」的風險（例如某個家庭成員數特別多，扇出的收件人特別多，讓
    這一批的併發送出耗時遠超預期）——`docs/PLAN.md` 的產品定位是**私密家庭相簿**，
    網域模型天生是小規模（一個家庭，不是企業級大量收件人的廣播系統），這個殘餘
    風險在現階段的實際邊界下可以忽略。**若日後產品假設改變**（例如支援多家庭
    批次廣播、或家庭規模上限大幅提高），這裡的設計前提需要重新評估，屆時應考慮
    改用批次大小依剩餘時間動態估算的版本。

- **文案彙總矩陣**（繁中、長輩可讀；`supabase/functions/push-dispatch/handler.ts`
  的 `buildMessageBody()`，依 `kind × event_count × target_type` 生成，目標標籤
  `diary→日記／album→相簿／media→照片／comment→留言`；`family` 標籤存在只是讓
  `Record<ContentTargetType, string>` 保持窮舉，`kind='media'` 的訊息不透過
  標籤組字，見下）：

  | kind | event_count = 1 | event_count > 1 |
  |---|---|---|
  | `comment` | 「{actor}在你的{標籤}留言」（例：「阿嬤在你的日記留言」） | 「你的{標籤}收到了 {N} 則新留言」 |
  | `reaction` | 「{actor}喜歡了你的{標籤}」 | 「{N} 個人喜歡了你的{標籤}」（例：「3 個人喜歡了你的照片」） |
  | `diary` | 「{actor}寫了一篇日記」 | 「{actor}新增了 {N} 篇日記」（防禦性分支，見下） |
  | `album` | 「{actor}新增了相簿」 | 「{actor}新增了 {N} 本相簿」（防禦性分支，見下） |
  | `media`（LS-175） | 「{actor}新增了一張照片」 | 「{actor}新增了 {N} 張照片」（例：「爸爸新增了 50 張照片」，票文原始範例） |
  | `report`（LS-175 R2，merge-review R1 m2） | 「你的{標籤}收到一則檢舉」 | 「你的{標籤}收到了 {N} 則檢舉」 |

  `actor` 取 `claim_notification_events()` 已 `COALESCE` 過的
  `actor_display_name`（`NULL` fallback「家人」）——**`report` 是唯一沒有用到
  `actor` 的分支**：`report_content()`（LS-149）寫入的 `actor_id` 是檢舉人，不是
  被檢舉內容的作者，沿用 `comment`／`reaction` 那種「{actor} 對你的 xxx 做了
  什麼」句型會讓收件人誤以為檢舉人在跟自己互動；`target_type` 用被檢舉內容原本
  的類型（`album`／`media`／`diary`／`comment`），`TARGET_LABEL` 可以直接沿用。
  這是**中性 fallback**，不是產品定案文案——`report` 事件從 LS-149 落地起就會
  寫進 `notification_events`，但 `push-dispatch`（LS-172）當時的型別守門
  （`isNotificationKind`／`isContentTargetType`）沒有涵蓋它，若被 claim 到會讓
  **整批**（不只 report 那幾筆）被判定失敗、SQL 面卻已標記 `sent_at`＝永久漏送
  （LS-96 池項 `841d97da`，merge-review R1 於 PR #284 覆核成立並裁定本票直接
  補）；本票只補到「不再整批漏送」，是否要推播、推播給誰（例如只給 owner）
  是後續的產品決定——**已由 LS-195 定案：只給 owner**，見上方
  `notification_recipients` 段的 `kind='report'` 收件人規則。

  **已知、刻意的規格分歧（票文字面 vs. 實際可用資料，`album`／`diary` 兩個既有
  kind，LS-172 落地時的記錄）**：票文給的範例把 `album` kind 對應到「爸爸新增了
  50 張照片」，但 `album` kind 只在**建立相簿本身**時觸發
  （`private.notify_album_created()`，見
  `20260825020000_comments_reactions_notifications.sql` §3），`target_id` 是每本
  相簿自己的 id——不同相簿天生無法合併（合併鍵含 `target_id`），`event_count`
  對這個 kind 在目前的 trigger 設計下**恆為 1**。這裡不虛構一個資料庫給不出來的
  數字，`album` 訊息改成不帶張數；`event_count > 1` 是防禦性分支（今天的 trigger
  設計下不會發生，日後若 schema 演進出「批次建立多本相簿合併通知」的需求，這個
  分支已經存在）。`diary` kind 同理。

  **LS-175 起，「批次上傳 50 張照片合併成一則」這個票文原始範例已經有真正的
  `kind='media'` 事件可用**（`media` 表自己的 `AFTER INSERT` trigger，見 §3
  「`media` 來源（LS-175）」）——`target_type` 恆為 `'family'`，不是所屬相簿／
  日記（結構性理由同上：`media` 表沒有 album_id／diary_id，trigger 觸發當下
  這批照片會不會、會掛進哪個相簿／日記這個資訊還不存在），所以
  `buildMessageBody()` 的 `media` 分支不使用 `TARGET_LABEL` 組出「在你的 xxx」
  這種子句，訊息本身就是完整句子。

- **失效 token 處理**（APNs 回 `410 Unregistered` 或 `400 BadDeviceToken`）：
  `push-dispatch` 直接 `DELETE FROM device_tokens WHERE token = $1`（`service_role`
  的欄位級 `SELECT (token)` ＋整表 `DELETE` grant，見
  `20260904095205_push_dispatch.sql` 檔頭第 4 段——**本機實測踩出的洞**：純
  `GRANT DELETE` 不夠，PostgreSQL 對帶 `WHERE` 條件的 `DELETE` 要求呼叫者對
  `WHERE` 子句引用到的欄位也要有 `SELECT` 權限，否則撞
  `permission denied for table device_tokens`）。其他錯誤（`BadTopic`／
  `TopicDisallowed` 等，`403 ExpiredProviderToken` 除外——見下方 ApnsProvider
  段的重簽重試）只記 log，不刪 token、不重試——那些是設定或憑證問題，不是
  「這支裝置不會再收到通知」。
  - **DELETE 真的刪到東西 vs. 該列本來就不存在（LS-172 R2，merge-reviewer
    i2）**：`index.ts` 的 `removeDeviceToken()` 在 `.delete()` 後接
    `.select("token")`——要求 PostgREST 用 `Prefer: return=representation`
    回傳實際被刪掉的列，藉此分辨「真的刪到東西」（回傳陣列長度 > 0）跟「該列
    本來就不存在」（DELETE 本身仍然成功，只是沒有列被刪，不是錯誤）。只請求
    `token` 這一欄，對齊上面欄位級 `select (token)` 的 grant——`.select()`
    預設的 `*` 會要求整表 SELECT 權限，撞 permission denied。
  - **`tokensRemoved` 計數只在真的刪到列時才累加、同一 token 同批次去重
    （LS-172 R2，merge-reviewer m2）**：`handler.ts` 的 `runDispatch` 用一個
    `Set<string>` 記錄本次 invocation 內已經處理過的 token——同一個 token 若是
    兩個不同事件的共同收件人（同一支裝置對兩篇日記都是收件人，剛好都判定失效），
    只會被 `DELETE` 一次、只計數一次。去重的「先佔位再 await」寫法（`Set.add()`
    緊接在 `Set.has()` 檢查之後、中間沒有任何 `await`）是有上限併發下避免同一個
    token 被兩個並發中的 job 都判定成「還沒刪過」而重複計數的關鍵——check-then-set
    在 JS 單執行緒下是原子的。

- **`ApnsProvider` 介面與五個 secrets**
  （`supabase/functions/push-dispatch/apns.ts`）：token-based auth（ES256 JWT，
  Web Crypto `crypto.subtle` 簽章，不需要額外套件）＋ HTTP/2（Deno 的 `fetch` 對
  HTTPS 端點自動協商 h2；APNs 的 HTTP/1.1 端點已於 2021 年除役，只接受
  HTTP/2）。需要以 `supabase secrets set` 設定五個 EF secrets：
  `APNS_TEAM_ID`／`APNS_KEY_ID`／`APNS_P8`（`.p8` 私鑰全文，PEM 格式，含
  `BEGIN`/`END` 行）／`APNS_BUNDLE_ID`／`APNS_ENV`（`"production"`；其他值皆視為
  sandbox，`https://api.sandbox.push.apple.com`——sandbox 是安全預設，不會因為
  忘記設定而誤打正式站）。**缺任一個立即在建構時丟出例外（fail loud，不送）**——
  在模組層級（`index.ts`）呼叫，isolate 冷啟動就會直接失敗，不會等到收到請求才
  發現、更不會悄悄降級成「不送」。
  - **JWT 過期處理（LS-172 R2，merge-reviewer M1）**：JWT 在同一個 provider
    實例內重複使用，不是每次 `send()` 都重簽（Apple 建議同一把 token 在效期內
    ——最長 1 小時——重複使用）。`index.ts` 把 `apnsProvider` 建在**模組層級**，
    同一個 isolate 存活期間的所有請求共用同一個實例，isolate 保持溫熱可以遠遠
    超過 1 小時——原本的實作誤以為「下一次 invocation 是全新的 provider 實例，
    天然過期」，這個假設與 index.ts 的實際建構方式矛盾，過期後每次 `send()` 都
    會收到 APNs `403 ExpiredProviderToken`，而 `push-dispatch` 是「先 claim 再
    送、送失敗不回滾」的語意（見上），代表過期後會是**永久漏送、無告警**。
    修法兩層：(a) 記錄簽發時間，超過 45 分鐘（保守值，留在 Apple 1 小時上限之前）
    就重簽；(b) 保底：即使 45 分鐘的估計不準，收到 `403 ExpiredProviderToken`
    時當場重簽一次並重試一次（不是無限重試，其他錯誤不觸發這個重試）。
- **`StubApnsProvider`**（`handler.ts`）：本機／CI 用，只記錄呼叫的
  `token`/`title`/`body`，不打真正的 APNs；可注入 `responder` callback 依 token
  回傳任意結果（含模擬 410，供測試驗證失效 token 清除路徑）。由環境變數
  `PUSH_DISPATCH_PROVIDER`（**非 secret**，純環境開關）選擇：明確設成 `"stub"`
  才用它；未設定或設成 `"apns"` 一律走真正的 APNs——「本機／CI 用 stub」必須是
  明確選擇，不是缺 APNs secrets 時的自動降級（那樣會讓「忘記設定正式 secrets」的
  部署錯誤被靜默吞掉）。
  - **`PUSH_DISPATCH_STUB_RESPONSE`（LS-96 池項 `531a0975`，非 secret，本機／CI
    測試開關，只在 `PUSH_DISPATCH_PROVIDER=stub` 時有意義）**：原本
    `StubApnsProvider()` 的 responder 只能在 deno 單元測試裡直接 construct
    `new StubApnsProvider(responder)` 才能注入 410／BadDeviceToken，`supabase
    functions serve` 起的真實 HTTP 端點沒有任何機制能讓 Stub E2E 驗到
    `tokens_removed`／`device_tokens` 刪列這條路徑（原本只能改用「打真正
    PostgREST DELETE」的等價驗證繞過去）。設成 `"410"` 時，`StubApnsProvider`
    對每一次 `send()` 呼叫都回傳失效 token（`invalidToken:true`），
    `runDispatch` 因此會真的呼叫 `removeDeviceToken()`。解析在
    `handler.ts` 的 `parseStubResponse`——**fail loud**：設了但不是 `"410"`
    就丟例外，不悄悄退回預設的 `ok:true`。未設定＝維持原本一律 `ok:true` 的
    行為。正式站部署不設定這個變數（只在 `PUSH_DISPATCH_PROVIDER=stub` 才有
    意義，正式站本來就不會設 `PUSH_DISPATCH_PROVIDER`）。
- **排程（未建立，僅記載部署清單）**：`pg_cron` 每分鐘一次呼叫 `pg_net.http_post`
  打本函式，`apikey` header 從 `vault` 讀取（不寫死在 migration 裡，LS-196 訂正
  ——不再是 `Authorization` header 帶 `service_role` key，見上方「鑑權」段與
  §6 `purge-storage` 的完整背景）——同 `purge-storage`（§6「自動清除」執行機制
  段）的既有排程形狀，差別只在頻率（`purge-storage` 每日一次，`push-dispatch`
  需要更即時，故每分鐘一次）與 vault secret 名稱：
  ```sql
  select net.http_post(
    url := '<SUPABASE_URL>/functions/v1/push-dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'ls172_push_dispatch_secret_key'
      )
    )
  );
  ```
  **本票不執行這段部署**，接排程由 orchestrator 依 LS-78 授權狀態決定時機。
- **本機測試**：
  - `supabase/functions/push-dispatch/{handler,apns}.test.ts`（Deno 內建
    `Deno.test`，注入 fake deps／fake `fetch`／`StubApnsProvider`，不需要跑
    `supabase functions serve`，不連線任何真正的服務）——`deno test`，共 48 案
    （R2 新增：時間預算 stoppedEarly、有上限併發、tokensRemoved 去重與
    deleted-flag、批次 getRecipients、bearer 長度不同分支、45 分鐘齡期重簽、
    403 ExpiredProviderToken 重簽重試一次）。`apns.test.ts` 用
    `crypto.subtle.generateKey` 產生一把測試用 P-256 金鑰對（不是任何真實 Apple
    憑證），驗證 `buildRealApnsProvider` 簽出的 JWT 能被對應公鑰
    `crypto.subtle.verify` 驗證通過——不是只檢查字串形狀。
  - `supabase/tests/103_push_dispatch.sql`：`claim_notification_events()`／
    `notification_recipients()` 的 SQL 面驗收（claim 兩次不重疊、封鎖對象排除、
    無 token 成員略過、跨家庭隔離、`actor_id` 為 `NULL` 時不誤傷任何人、批次呼叫
    的 `event_id` 分組正確、`device_tokens` 授權邊界）。
  - **`supabase/tests/concurrency/push_dispatch_claim_race_*.sql`／
    `push_dispatch_claim_vs_record_*.sql`（LS-172 R2，merge-reviewer i5）**：
    比照既有 `race_case` 機制（`supabase/tests/run.sh`）的常駐、可重跑併發
    regression test，不是手動驗一次就結案：
    1. 兩個真正並行的 `claim_notification_events()` 呼叫（各 `p_limit=5`、10 筆
       待送事件）——claim 到的事件集合交集必須是空集合（`FOR UPDATE SKIP
       LOCKED` 保證不重疊）。
    2. `claim_notification_events()` 跟既有 LS-58 trigger
       `record_notification_event()`（5 分鐘視窗彙總）幾乎同時碰同一個目標——
       S1 claim 走一筆已穩定的舊事件並壓住交易，S2 用真正的 `create_comment()`
       RPC（跟 production 呼叫路徑一致）對同一目標建立新留言；驗證 claim 標記
       `sent_at` 之後，新留言不會誤合併進已 claim 的舊列，而是正確開新列。
       **本機實測修正**：原本預期這裡是靠「`SELECT ... FOR UPDATE` 被鎖卡住、
       解鎖後 EvalPlanQual 重新檢查 WHERE 子句」保護，實測發現不成立——
       `claim_notification_events()` 的候選條件（`occurred_at < now()-5min`）
       跟 `record_notification_event()` 的合併條件（`occurred_at >= now()-5min`）
       對同一個 `now()` 求值是嚴格互補、零重疊的，`record` 的 SELECT 在掃描階段
       就已經被 occurred_at 排除掉這一列，從未嘗試對它取鎖，因此不會被 claim
       卡住。真正保護這個不變量的是 occurred_at 過濾本身，`sent_at is null`
       只在 5 分鐘視窗內才有意義（詳細分析見
       `push_dispatch_claim_vs_record_s2_comment.sql` 檔頭）。測試本身仍然用
       真正並行的兩個 session 驗證最終狀態正確，不是改回序列測試。
  - **本機 Stub 端到端**（票驗收條件要求的手動驗證，見票 handoff）：灌 3 個家庭
    成員（其中 1 人封鎖 actor）＋一筆已穩定的批次事件，用
    `PUSH_DISPATCH_PROVIDER=stub` 呼叫本函式（`supabase functions serve`）——
    只對 1 位非封鎖成員發 1 則彙總；claim 後重跑同一批呼叫 0 則。**LS-182**：
    另外加 `PUSH_DISPATCH_STUB_RESPONSE=410` 可以在同一個 Stub E2E 流程注入
    410，觀察 `tokens_removed` 與 `device_tokens` 實際刪列（見上方
    `PUSH_DISPATCH_STUB_RESPONSE` 說明）。
- **已知限制**：真正的 APNs 呼叫（`buildRealApnsProvider` 的 HTTP 送出本身）沒有
  對真正的 Apple 伺服器做過端到端驗證——需要 LS-8（Apple Developer Program 付費
  帳號）到位、拿到真正的 `.p8` 金鑰後才能在真機驗證，同 `delete-account`
  Apple／Google 撤銷的既有先例。JWT 的簽章正確性（ES256、header/payload 形狀）
  已用測試金鑰對驗證過（見上方 `apns.test.ts`），未驗證的只是「Apple 伺服器
  真的接受這把 JWT」這一步。
- **部署**（正式站，orchestrator 依 LS-78 授權狀態執行，不在本票落地範圍）：
  ```
  supabase functions deploy push-dispatch --project-ref mzkkkzbiejgvhwjyiokf
  supabase secrets set APNS_TEAM_ID=... APNS_KEY_ID=... APNS_BUNDLE_ID=... APNS_ENV=production
  supabase secrets set APNS_P8="$(cat AuthKey_XXXXXXXXXX.p8)"
  ```
  `SUPABASE_URL`／`SUPABASE_SECRET_KEYS`／`SUPABASE_SERVICE_ROLE_KEY` 由
  Supabase 平台自動注入，不需要另外設定（LS-196：admin client 與鑑權判定改用
  `resolveSecretKey()`／`isAuthorizedServiceCall()`，見上方「鑑權」段）；
  `PUSH_DISPATCH_PROVIDER` 正式站不設定（預設值 `"apns"` 即為正確行為）。

---

## 11. 營運操作手冊

LS-179（PLAN §10-A(3)／§10-B）：以下全部是**表擁有者**（Dashboard SQL Editor／
`supabase db query --linked`，兩者皆以 `postgres` 身分執行——`service_role` 目前
對這幾張表沒有 INSERT/UPDATE/SELECT 的 table grant，`BYPASSRLS` 只繞過 RLS、
不等於有 table privilege，R2 merge-review m4 實測 catalog 確認；若之後有
Edge Function 需要直接寫入，須另外明確 `grant ... to service_role`）手動下的
SQL，**改欄位當下立即生效，不需要改任何程式碼或重新部署**。實作見
`supabase/migrations/20260904212530_suspension_and_registrations.sql`；三者
共用的判斷 helper（`private.caller_is_active()`／`private.family_is_active(uuid)`／
`private.registrations_open()`）只讀對應旗標，不做任何額外邏輯。下方「更新
EULA 版本」是同一種手法的延伸（LS-197，實作見
`supabase/migrations/20260905051320_eula_consent.sql`），差別只在 `eula_version`
這一欄額外開了 client 端的欄位級 `SELECT`（見 §2／§3）。

**停權原因存在 `private.suspension_notes`（R2，MAJOR-1），不在 `profiles`／
`families` 上**——那兩張表對 `authenticated` 是表級 SELECT，任何欄位都會被
自動涵蓋，稽核原因不能放在那裡；`private` schema 對 `authenticated`／`anon`
只有 `usage`，沒有任何表格級 grant，這張表因此只有表擁有者讀寫得到。

### 停權一位使用者

```sql
update public.profiles set suspended_at = now() where id = '<user_id>';
insert into private.suspension_notes (subject_type, subject_id, reason)
values ('user', '<user_id>', '寫下原因（稽核用，client 讀不到）')
on conflict (subject_type, subject_id) do update set reason = excluded.reason, created_at = now();
```

生效範圍：這個使用者對「所有」家庭資料（不限於他目前所屬的家庭）的 RLS 讀寫、
Storage 讀寫上傳、既有 RPC 入口一律拒絕（`LS052`）；不影響其他使用者。他自己的
`profiles` 列（顯示名稱／頭像）與已核發、尚未過期的簽名 URL 不受影響（簽名 URL
本就短效，見 §6，本票不做撤銷）。**`delete_my_account()` 不受影響**（R2，
MAJOR-2）——被停權的使用者仍然能在 app 內刪除自己的帳號，這是 App Store
Guideline 5.1.1(v) 的硬規定，見 §4。

**解除停權**：

```sql
update public.profiles set suspended_at = null where id = '<user_id>';
delete from private.suspension_notes where subject_type = 'user' and subject_id = '<user_id>';
```

### 停權整個家庭

```sql
update public.families set suspended_at = now() where id = '<family_id>';
insert into private.suspension_notes (subject_type, subject_id, reason)
values ('family', '<family_id>', '寫下原因')
on conflict (subject_type, subject_id) do update set reason = excluded.reason, created_at = now();
```

生效範圍：這個家庭的全部成員（不分 owner／member／viewer，**含建立者本人**——
R2 訂正，見 §3 `families` 的 `suspended_at` 說明）對這個家庭的資料一律拒絕
讀寫（`LS053`）；成員若還屬於其他（未停權的）家庭，對那些家庭不受影響
（Phase 3 多家庭前置）。**該家庭裡任何成員的 `delete_my_account()` 依然可用**
（R2，MAJOR-2）。

**解除**：
```sql
update public.families set suspended_at = null where id = '<family_id>';
delete from private.suspension_notes where subject_type = 'family' and subject_id = '<family_id>';
```

### 關閉／重新開放新註冊

```sql
update public.app_settings set registrations_open = false, updated_at = now() where id = true;
```

生效範圍：**只擋自建新家庭**這一步（`LS054`）——既有使用者登入、既有家庭憑邀請
碼加入完全不受影響（PLAN §10-A(3) 的取捨：本票只做「關掉」，不做「候補名單」）。
Auth 端（Apple／Google／Email 註冊）也不受影響，避免與登入流程打架。
`delete_my_account()` 不受影響（自建家庭與刪帳號是兩條互不相干的路徑）。

**重新開放**：`update public.app_settings set registrations_open = true, updated_at = now() where id = true;`

### 更新 EULA 版本（LS-197，PLAN §6 第 7 項／§10-B）

```sql
update public.app_settings set eula_version = '<新版號>', updated_at = now() where id = true;
```

生效範圍：立即生效，不需要改程式碼或重新部署。既有已同意舊版本的使用者
`profiles.eula_accepted_version` 不會被連動改動，只有他們下一次呼叫
`accept_eula()` 時的比對基準會變成新版號——`p_version` 若還是舊版號一律回
`LS055`，逼呼叫端重新抓一次目前版本、重新顯示條款（見 §4）。**同意紀錄可
稽核**：`profiles.eula_accepted_version`／`eula_accepted_at` 兩欄只能透過
`accept_eula()` 寫入（client 直接 `.update()` 一律 `42501`，見 §3），任何一次
同意都會留下當時的版本與時間戳，不會被使用者自己竄改。

**本節（§11）下方所有 SQL 皆以表擁有者（postgres）身分執行，`where id = true`
在這個身分下沒有問題。client 端（`authenticated`）讀 `eula_version` 絕對不能
照抄這個寫法**——見 §4 `accept_eula` 的說明：`id` 沒有欄位級 `SELECT` 權限，
WHERE 子句引用到它一律 `42501`，client 端要用不帶任何 WHERE 的
`select eula_version from app_settings limit 1`。

### 查目前狀態

```sql
select id, suspended_at from public.profiles where suspended_at is not null;
select id, name, suspended_at from public.families where suspended_at is not null;
select * from private.suspension_notes;
select registrations_open from public.app_settings where id = true;
select eula_version from public.app_settings where id = true;  -- 表擁有者身分查詢，client 端見 §4 的替代寫法
select id, eula_accepted_version, eula_accepted_at from public.profiles
 where eula_accepted_version is not null;
```
