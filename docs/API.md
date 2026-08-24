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
> LS-33／LS-36／LS-37／LS-40）。

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
- **沒有 `anon` 角色的資料存取**：`anon` 對 16＋1 張表與全部 8 支 RPC 都沒有任何權限
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
| `families` | 我所屬的家庭 | 任何登入者（自建家庭） | 僅 `name` 欄，owner-only | ❌ 無 delete policy | 額度欄位（`storage_quota_bytes`／`storage_used_bytes`）與 `require_approval` 以外的所有欄位皆不可由 client 直接改 |
| `family_members` | 我所屬家庭的成員 | 🔒 **RPC-only**（`request_join`／`approve_join`，直接 INSERT 已被 revoke） | 僅 `role`／`can_upload` 兩欄，owner-only | owner 移除任何人；任何人可自行退出 | LS-33/LS-6 收斂：不存在「owner 直接把任意 user_id 塞進成員名單」的路徑 |
| `invites` | owner 看自家的邀請碼 | 🔒 **RPC-only**（`create_invite`，直接 INSERT 已被 revoke） | 🔒 **無 UPDATE 路徑**（policy 與 grant 兩層都關，LS-37） | owner 撤銷（DELETE，cascade 掉底下的 pending 申請） | 撤銷邀請碼＝DELETE 該列，沒有「軟撤銷」欄位 |
| `children` | 我所屬家庭的孩子 | owner-only | owner-only | owner-only | Member/Viewer 唯讀 |
| `media` | 我所屬家庭的檔案中繼資料 | 有上傳權者（`uploaded_by` 必須是自己） | 僅 `taken_at`／`deleted_at`／`width`／`height` 四欄；owner 任意列，上傳者僅自己上傳的 | 硬刪僅 owner（一般刪除走 `deleted_at`） | `byte_size`／`storage_path`／`family_id`／`uploaded_by` 一旦寫入不可改 |
| `albums` | 我所屬家庭的相簿 | owner／member（`created_by` 必須是自己） | owner 任意列；建立者僅自己建立的 | owner-only | Viewer 不可建立相簿 |
| `album_media` | 同上 | owner／member | owner／member | owner／member | 連結表自帶 `family_id`，policy 不必 join 回 `albums` |
| `diaries` | 我所屬家庭的日記 | owner／member（`author_id` 必須是自己） | owner 任意列；作者僅自己寫的 | owner-only | 同 `albums` 模式 |
| `diary_media` | 同上 | owner／member | owner／member | owner／member | 同 `album_media` |
| `comments` | 我所屬家庭 | **任何角色**（含 viewer） | owner 任意列；作者僅自己的 | owner-only | Viewer 能留言，符合 PLAN §3 |
| `reactions` | 我所屬家庭 | **任何角色** | ❌ 無 update policy（收回愛心走 DELETE） | 僅自己按的 | `UNIQUE(target_type, target_id, user_id)`：同一目標重複按會拿到 `23505` |
| `device_tokens` | 僅自己的裝置 | ⚠️ 見下方 | 僅自己 | 僅自己 | **換裝置／換帳號登入請務必呼叫 `register_device_token` RPC，不要直接 INSERT／UPSERT**（見 §4） |
| `feed_items` | 我所屬家庭的時間軸 | 🔒 唯讀（trigger 維護） | 🔒 唯讀 | 🔒 唯讀 | 沒有任何 client 可寫入的路徑，連 grant 都沒有 |
| `content_reports` | 自己送出的＋（若是 owner）自家的 | **任何家庭成員** | 僅 `status` 欄，owner-only，且只能改成 `resolved`（不能 `dismissed`） | ❌ 無 delete policy | 駁回（`dismissed`）保留給平台方用 `service_role`／Dashboard 處理 |
| `blocked_users` | 僅自己封鎖的名單（`blocker_id = 我`） | 僅自己 | ❌ 無 update policy | 僅自己 | 被封鎖者看不到自己被封鎖 |
| `join_requests` | 自己送出的申請＋（若是 owner）自家的待審申請 | 🔒 **RPC-only**（`request_join`） | 🔒 **RPC-only**（`approve_join`／`reject_join`／`withdraw_join`） | 🔒 無 delete policy | 沒有任何 client 直接寫入路徑，grant 只有 SELECT |

**寫入路徑小結（給 iOS 呼叫端的心智模型）**：`family_members`／`invites`／`join_requests`
三張表**完全不能**用 `.insert()`／`.update()`（`family_members` 的 `role`／`can_upload`
例外，見上表），一律呼叫對應 RPC；其餘表可用 PostgREST 的 `.from(...)` 直接讀寫，但每張表
都有欄位級或列級限制，寫超出範圍會拿到 `42501`（grant 層）或該欄位的 `CHECK`/`NOT NULL`
違反碼（policy 通過但值不合法）。

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

### `albums` / `diaries`
- `child_id` 可為 `NULL`（家庭共用內容，不特別掛在某個孩子底下）；非 NULL 時必須是
  同一家庭的孩子（複合外鍵，見 §8）。
- Owner 可編輯／刪除任何一筆；member 只能改自己建立的（Viewer 完全不能建立）。

### `album_media` / `diary_media`
- 純連結表，自帶 `family_id`（不必 join 回 `albums`/`diaries` 判斷歸屬）。
- 兩條複合外鍵確保「A 家的相簿掛 B 家的照片」在 DB 層建不起來，不只是 RLS 擋。
- 同一張 `media` 可以同時出現在多個相簿／日記裡（沒有「一張照片只能屬於一個相簿」的
  約束）。

### `comments` / `reactions`
- `target_type` ∈ `album|media|diary|comment`，`target_id` 是對應表的 `id`。**這是
  多型關聯，DB 無法對它下外鍵**——傳一個不存在的 `target_id` 不會被 DB 擋下（沒有
  `23503` 可用），孤兒留言的清理是應用層或定期清理的責任，不是 API 的錯誤處理範圍。
- `reactions` 每人對同一目標只能有一顆愛心（`UNIQUE(target_type, target_id, user_id)`）；
  重複按會拿到 `23505`，client 應該先查有沒有按過，或把 `23505` 當成「已經按過」處理，
  不要當成失敗。

### `device_tokens`
- **不要**直接 `.upsert()` 或 `.insert()`／`.delete()` 這張表。同一支裝置換帳號登入時，
  三條直接路徑都走不通（見 §4 `register_device_token` 的說明），會留下跨帳號的推播
  外洩風險。**永遠透過 `register_device_token` RPC**。

### `feed_items`
- 純唯讀，`kind ∈ album|media|diary`，`occurred_at` 依 kind 各自取（album 用
  `created_at`；media 用 `coalesce(taken_at, created_at)`；diary 用 `entry_date`
  轉 UTC 午夜）。分頁用 keyset：`WHERE family_id = ? AND (occurred_at, ref_id) < (?, ?)
  ORDER BY occurred_at DESC, ref_id DESC LIMIT n`，不要用 `OFFSET`。

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

呼叫方式：`supabase.rpc("函式名", params: [...])`（supabase-swift）。全部 8 支都是
`SECURITY DEFINER`，只對 `authenticated` 開放（`anon`／`public` 已逐支 revoke，見
`supabase/tests/60_default_privileges.sql` 的正向對照）。

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
- **錯誤碼**：未登入 `42501`；申請不存在 `LS015`；不是該家 owner `42501`（**排在
  狀態檢查之前**——不是 owner 的人不管申請是什麼狀態一律拿 `42501`，不會從錯誤碼差異
  推敲出某個 request id 存不存在）；申請已被處理（非 pending）`LS015`。
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

---

## 5. 錯誤碼全表

自訂 `SQLSTATE` 一律是 `LS0xx`/`LS1xx` 格式（5 碼英數，符合 Postgres 自訂 errcode 慣例）。
Swift 端後續實作 `LSError` enum 時（見下方「未涵蓋於本票」）應逐碼列舉，不要用字串比對。

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
| `LS016` | 邀請碼產生連續撞碼，請重試 | `create_invite`（機率極低，代表亂數來源異常，不是使用者可修正的錯誤，UI 顯示通用重試訊息即可） |
| `LS017` | 邀請碼參數不合法（到期時間或可用次數超出範圍） | `create_invite` |
| `42501` | 未登入，或權限不足（不是該家 owner／不是申請人本人／直接寫入被 grant 擋下） | 所有 RPC 皆可能；也是**任何直接對 RPC-only 表寫入**（如 `family_members` INSERT、`invites` INSERT/UPDATE、`join_requests` 任何寫入）會拿到的標準碼——PostgREST 對 grant 被收回的操作回這個碼，訊息只會是通用的 permission denied，不會有自訂文字 |

**沒有被上面任何一支 RPC 包住、可能直接從 PostgREST 冒出來的標準 Postgres 錯誤碼**
（直接 `.insert()`/`.update()` 到允許直寫的表時可能撞到，client 應該當成一般失敗處理，
不必逐碼分文案，除非產品需求特別要求）：

| 碼 | 常見觸發情境 |
|---|---|
| `23502`（`not_null_violation`） | 必填欄位留空，例如 `children.birthday`、`media.byte_size` |
| `23514`（`check_violation`） | 違反欄位 `CHECK`，例如 `families.name` 長度、`media.width/height > 0`、`diaries.body` 長度 |
| `22P02`（`invalid_text_representation`） | enum 欄位傳了不合法的字串（例如 `role` 不是 `owner/member/viewer`） |
| `23505`（`unique_violation`） | 例如 `reactions` 重複按讚、`blocked_users` 重複封鎖同一人 |
| `23503`（`foreign_key_violation`） | 例如 `albums.child_id` 指到別家的孩子（複合外鍵擋下） |

**未涵蓋於本票（LS-41）的範圍，記錄供後續票參考**：Swift 端 `LSError` enum 對映全碼＋
列舉式單元測試，是原始 ticket scope 的一部分，但目前 repo 尚未有任何網路層 Swift 程式碼
（`LittleSprout/` 底下沒有任何呼叫 Supabase 的程式碼），orchestrator 派工時把本票範圍收斂
為「文件＋對帳 gate」，Swift 端留給第一張真正呼叫這些 RPC 的 UI 票（LS-17 起）一併實作，
到時候直接對照本節的表即可。

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

---

## 9. 機械對帳清單（gate 讀取，勿手動改格式）

以下兩個區塊由 `scripts/gates/api-contract-check.sh` 解析：每行一個項目，`<!-- API-CONTRACT:RPC`
與 `<!-- API-CONTRACT:TABLES` 開頭、`-->` 結尾之間的內容必須恰好等於從
`supabase/migrations/*.sql` 抽出的 `public` schema RPC 簽章與表名清單（順序不拘，多一項
少一項都會讓 gate 變紅）。**改 schema 時，先跑一次 `bash scripts/gates/api-contract-check.sh`
確認紅燈的差異訊息，再回來同步這兩個區塊**——不要手動猜測格式。

<!-- API-CONTRACT:RPC
approve_join(uuid)
create_invite(uuid, text, timestamptz, integer)
get_my_join_request()
list_join_requests()
register_device_token(text, text)
reject_join(uuid)
request_join(text)
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
profiles
reactions
-->
