# Little Sprout 🌱 — 家庭相簿與日記 App 規劃

> 一個給家人分享小孩照片、影片與成長日記的 iOS app。
> 私密、簡單、以「家庭」為單位，支援多個家庭各自分享自己的孩子。

## 1. 產品定位

- **對象**：自己家人為主（爸媽、祖父母、親戚），其他親友家庭也能建立自己的家庭空間分享他們的孩子。
- **不是**公開社群，沒有陌生人、沒有演算法、沒有廣告。
- 加入方式：**邀請連結／邀請碼**，不開放註冊後自由搜尋。
- **發佈路線**：初期只開放親友使用；**終局目標是 App Store 公開上架（listed）**。
  - **開發期一律按 listed 標準準備**，不留技術債 —— 送審規定、營運防線（§10）、對陌生使用者的可用性都當作 MVP 範圍做滿。真的要上架時只剩送審文書，不必回頭改架構。
  - 判準：**不可逆的決定現在想清楚**（帳號型態、bundle ID、資料模型、版面架構）；**可逆的實作直接做滿**（UI、文件、版面適配）。

## 2. 核心功能（MVP）

| 功能 | 說明 |
|---|---|
| 家庭空間 (Family) | 每個家庭一個空間，成員透過邀請連結加入；一個帳號可屬於多個家庭（例如同時看自己家和妹妹家的小孩） |
| 孩子檔案 (Child) | 姓名/暱稱、生日、大頭照；照片與日記都掛在孩子底下，可自動顯示「1 歲 3 個月」這種年齡標記 |
| 相簿 (Album) | 建立相簿、批次上傳照片/影片、封面、依日期排序 |
| 時間軸 (Timeline) | 家庭首頁按時間倒序混合顯示新相簿、新照片、新日記 |
| 日記 (Diary) | 文字 + 可附多張照片/影片，記錄日期可回填（補記昨天的事） |
| 互動 | 留言、愛心（讓長輩有參與感，也是 MVP 黏著度來源） |
| 推播通知 | 有新照片/日記/留言時通知家庭成員 |
| 檢舉／封鎖 | 檢舉內容、封鎖使用者、Owner 移除內容。**因上架而納入 MVP**（Guideline 1.2，見 §9-A1） |
| 帳號刪除 | app 內可刪除帳號，含家庭轉移或銷毀。**因上架而納入 MVP**（Guideline 5.1.1(v)，見 §9-A2） |

**MVP 先不做**（第二階段再說）：影片轉檔串流（HLS）、自動臉部辨識分類、照片自動備份整卷上傳、年度回顧/成長曲線、Android 版。

## 3. 角色與權限

| 角色 | 權限 |
|---|---|
| Owner（家長） | 管理家庭、邀請/移除成員、建立孩子檔案、發佈與刪除所有內容。**一個家庭可有多位 Owner**（爸媽各一個），且必須恆有至少一位 |
| Member（家人） | 看內容、留言、按愛心；預設**可**上傳照片（祖父母也會拍照），可由 Owner 關閉（承載欄位：`family_members.can_upload`，per-member 而非整個家庭一刀切） |
| Viewer（親友） | 只能看與留言 |

跨家庭原則：資料完全以 family 隔離，A 家庭成員看不到 B 家庭任何內容，除非也被邀請進 B 家庭。

**為什麼允許多 Owner**：不只是方便。App Store 規定 app 內必須能刪除帳號（見 §9），一旦唯一的 Owner 刪帳號，整個家庭與所有人的照片就懸空了。允許多 Owner + 刪除前強制轉移，是讓「刪帳號」這件事有解的前提。這是設計時免費、事後補要動權限模型的東西。

## 4. 技術架構

### 客戶端：Swift + SwiftUI（原生 iOS）

- 最低支援 iOS 17，用 SwiftUI + Swift Concurrency（async/await）。Swift 6 語言模式（strict concurrency）——LS-12 核定，資料競態於編譯期攔截。
- **iPhone + iPad 通用（universal）** ✅ 已定。**第一天就用適配式版面**：`NavigationSplitView` + size class，不要先做 iPhone 單層 stack 再回頭塞 iPad —— 導航層事後重寫是本專案少數「agent 也救不了」的返工，因為它會牽動每一個畫面。
- 照片選取用 `PhotosPicker`；上傳前在裝置端壓縮（照片轉 HEIC/JPEG ~2048px 長邊、影片用 `AVAssetExportSession` 壓到 1080p），大幅省儲存費用與上傳時間。
- 圖片快取：縮圖 + 原圖分開存，列表只載縮圖。

### 後端：Supabase（雲端起步）

| 需求 | 方案 |
|---|---|
| 帳號 | Supabase Auth（Sign in with Apple 為主 — App Store 規定有第三方登入就必須提供；Email OTP 給長輩備用） |
| 資料庫 | Postgres + **Row Level Security**：權限規則直接寫在資料庫層，「不是這個 family 的成員就查不到資料」由 DB 保證，不靠 app 端判斷 |
| 檔案儲存 | Supabase Storage（**S3 相容介面**），私有 bucket + 簽名 URL，照片影片不會有公開網址 |
| 推播 | Edge Function 觸發 APNs；裝置 token 存 `device_tokens` 表。**必須彙總**：批次上傳 50 張照片要合併成一則「爸爸新增了 50 張照片」，逐張發通知會讓家人第一天就關掉通知權限 |

### 為什麼這樣選（對應你的三個條件）

1. **iOS app** → 原生 SwiftUI 體驗最好，單一平台不需要跨平台框架的成本。
2. **先雲端、預留轉移 NAS** → app 只透過 **S3 相容 API + 抽象化的 StorageService** 存取檔案，所以**檔案儲存**的遷移成本確實被限制在設定層（NAS 跑 MinIO + `pg_dump` + S3 sync）。
   但要誠實記錄：被抽象掉的只有 Storage，**Auth 與 Push 沒有**。self-host 之後要自己簽發 JWT、自己輪替 Sign in with Apple 的 client secret（每 6 個月一次）、Edge Function 的 Deno runtime 也得自己養。所以 NAS 遷移不是「只改 endpoint」，見第 6 節 Phase 4 的兩條路線。
3. **多家庭** → 資料模型從第一天就以 `family_id` 為隔離邊界（見下），之後不用重構。

## 5. 資料模型

```
profiles         (id → auth.users.id, display_name, avatar_url)
families         (id, name, created_by, created_at, storage_quota_bytes, storage_used_bytes)
family_members   (family_id, user_id, role, can_upload, created_at)
                                                     -- PK (family_id, user_id); role: owner/member/viewer
invites          (id, family_id, code, role, created_by, max_uses, used_count, expires_at)
children         (id, family_id, name, birthday, avatar_url, created_at)
albums           (id, family_id, child_id?, title, cover_media_id?, created_by, created_at)
media            (id, family_id, storage_path, type: photo/video, taken_at,
                  width, height, uploaded_by, created_at, deleted_at?)
album_media      (album_id, media_id, sort_order)    -- PK (album_id, media_id)
diaries          (id, family_id, child_id?, author_id, body, entry_date, created_at, deleted_at?)
diary_media      (diary_id, media_id, sort_order)    -- PK (diary_id, media_id)
comments         (id, family_id, target_type, target_id, author_id, body, created_at, deleted_at?)
reactions        (id, family_id, target_type, target_id, user_id)
                                                     -- UNIQUE(target_type, target_id, user_id)
device_tokens    (user_id, token, platform, updated_at)
feed_items       (family_id, kind, ref_id, occurred_at)
                                                     -- kind: album/media/diary；由 trigger 維護
content_reports  (id, family_id, target_type, target_id, reporter_id, reason, status, created_at)
blocked_users    (family_id, blocker_id, blocked_id, created_at)
                                                     -- PK (family_id, blocker_id, blocked_id)
```

**掛載關係為什麼拆成連結表**：原本的 `media(album_id?, diary_id?)` 允許「兩個都空」與「兩個都填」這種無效狀態，而且一張照片無法同時出現在相簿和日記 —— 但那正是日記的自然用法（日記附的照片理應也進該孩子的相簿）。改成 `album_media` / `diary_media` 後 `media` 只負責檔案本身，順帶解掉 `albums.cover_media_id` ↔ `media.album_id` 的循環外鍵（原設計要 deferrable 才建得起來）。

**`feed_items` 為什麼第一天就要有**：時間軸要混排相簿/照片/日記，跨三張表 union 再排序，用 OFFSET 分頁在資料長大後會慢且會跳項。用一張由 trigger 維護的扁平表配 keyset 分頁（`WHERE occurred_at < $cursor ORDER BY occurred_at DESC LIMIT n`）。事後補要重寫整個首頁查詢，所以不列為優化項。

**RLS**：所有內容表都帶 `family_id`，policy 一律檢查 `family_id IN (使用者所屬家庭)`。**不要直接內嵌子查詢**——一律包成 `STABLE SECURITY DEFINER` 函式（或把 family 清單放進 JWT custom claim）。必定逐列重算、必慢的形狀是 **aggregate／correlated 子查詢**（子查詢裡引用了外層資料列的欄位，且包在聚合函式內，規劃器無法拉平成 join，只能逐列跑一次 SubPlan），例如 `(SELECT count(*) FROM family_members fm WHERE fm.family_id = m.family_id AND fm.user_id = auth.uid()) > 0`。**等值形**（如 `family_id IN (SELECT family_id FROM family_members WHERE user_id = auth.uid())`，子查詢不引用外層欄位）規劃器通常會拉平成 hashed SubPlan／semi-join 一次求值，但那是規劃器依估計列數與 `work_mem` 做的選擇，**不是保證**——雜湊表放不進 `work_mem` 時一樣會退化成逐列的 `(SubPlan N)`，一樣會被 `supabase/tests/50_rls_plan_no_percall_subquery.sql` 的偵測器擋下（判的是 plan 形狀，不是 SQL 寫法）。這正是規則寫成「一律包函式」而不是「等值形可以裸寫」的原因：包函式不必賭資料量會不會超過 `work_mem`。

**其他約束**：
- `invites` 的 `max_uses` / `used_count` 是隱私要求不是便利功能 —— 可無限重用的邀請碼一旦外流就是陌生人進家庭，與「私密」定位直接衝突。
- 內容表一律 soft delete（`deleted_at`）。長輩誤刪照片是高機率事件，硬刪沒有救援路徑。
- `comments` / `reactions` 用 `target_type + target_id` 多型關聯，代價是 Postgres 無法對它下外鍵約束，孤兒資料得靠應用層或定期清理處理。這個代價可接受（省掉每種 target 一張表），但要知道它存在。
- `content_reports` / `blocked_users` 是 App Store UGC 規定的承載表（§9-A1）。**表與 RLS 第一天就建、UI 可以晚點做** —— 事後才加會需要回頭補 migration 與 policy，現在建幾乎不花成本。
- **每個 family 必須恆有 ≥1 位 owner**：用 trigger 或 `DELETE`/`UPDATE` 前檢查來保證，別只靠 app 端擋。這條約束是帳號刪除流程能成立的基礎。
- **`families.storage_quota_bytes` / `storage_used_bytes` 是公開上架的必要防線**（§10-A）：公開之後任何人都能註冊並上傳到你付費的 bucket，沒有上限就是把信用卡交給陌生人。`storage_used_bytes` 由上傳/刪除時的 trigger 維護，超額時擋下上傳。欄位現在加幾乎免費，事後補要回頭算所有既有資料。

**檔案路徑規約**：`{family_id}/{yyyy}/{mm}/{media_id}.{ext}` + `..._thumb.jpg`，未來 S3 sync 到 NAS 時整個前綴搬走即可。`{yyyy}/{mm}` **取上傳時間，不取 `taken_at`** —— 這個前綴的用途是搬移分片而非查詢，用 `taken_at` 會讓回填舊照片時分片散開。

## 6. 開發路線圖

> 各階段的週數是「手寫程式」的量級估算，供排序參考。實際採 agent 主力開發，瓶頸不在打字而在**驗證**與**外部等待**（Apple 審核、家人試用回饋）—— 所以每步的「驗證：」條件才是真正的進度閘門，週數不是。

### Phase 0 — Harness（先建好開發與驗證環境，再開始寫功能）
1. 建 Xcode 專案（SwiftUI, iOS 17）+ SwiftLint → 驗證：模擬器跑出空殼 app
2. 建 Supabase 專案，寫 schema migration + RLS policies → 驗證：**(a)** SQL 測試證明跨 family 查不到資料；**(b)** 灌幾萬列假資料後 `EXPLAIN` 證明 policy 沒有 per-row 子查詢（隔離對了但會慢的 RLS 等於要重寫）
3. XCTest 跑起來 + GitHub Actions CI（build + test）→ 驗證：先推一個**刻意會失敗**的 RLS 測試讓 CI 變紅，再修掉它。綠燈本身不能證明 CI 真的在跑測試
4. 註冊 Apple Developer Program（**個人名義**，US$99/年）→ 驗證：能建立 App ID、啟用 Sign in with Apple、產出 APNs key、在 App Store Connect 建立 app 記錄
   - **第 1–3 步不需要付費帳號**（模擬器與實機測試用免費 Apple ID 即可，profile 7 天過期不影響開發）。
   - 但 **Sign in with Apple（Phase 1-1）與推播（Phase 1-6）都是付費會員才能啟用的 capability**，所以帳號必須在 Phase 0 結束前到位。個人名義線上刷卡即可，沒有 D-U-N-S 等待期，不會卡進度。
   - 順手把 **bundle ID 與 app 名稱佔下來**（建立 app 記錄即可，不必送審）。名稱先搶先贏，且上架後改名代價高。

### Phase 1 — 單一家庭 MVP（約 5–7 週的下班時間量）
1. Sign in with Apple 登入 → 驗證：登入後拿到 user
2. 建立家庭、邀請連結加入 → 驗證：第二支測試帳號可加入；**且全新帳號在沒有任何邀請碼的情況下，能自己建立家庭並邀請他人**（公開上架的最低可用性要求，見 §9-C5）
3. 孩子檔案 CRUD → 驗證：年齡標記正確
4. 相簿 + 照片上傳（含壓縮、縮圖、**背景上傳與失敗重試**）→ 驗證：2 支裝置互看；上傳 30 張到一半切出 app，回來會續傳完成
   - 背景上傳（`URLSession` background configuration）與壓縮同一個等級，不是優化項：手機傳幾十張照片中途切出 app 是常態，斷掉就重來會直接毀掉體驗
5. 日記發佈 + 時間軸 → 驗證：時間軸混排正確
6. 留言/愛心 + 推播 → 驗證：B 裝置收到 A 上傳的通知
7. 檢舉／封鎖／移除內容 UI + EULA 同意流程 → 驗證：被封鎖者的留言在對方視圖消失、Owner 收得到檢舉；**檢舉會進到你看得到的地方**（§10-B：公開上架後你是平台方，不能只讓 Owner 自理）
   - 同步做每家庭儲存額度上限（§10-A）→ 驗證：超額時上傳被擋且提示清楚
8. app 內帳號刪除 → 驗證：唯一 Owner 刪帳號時被要求先轉移；轉移後家庭與照片完好
9. TestFlight 發給家人實測 → 驗證：真人用得下去，且已具備送審所需的全部功能

> 第 7、8 步是上架規定帶進來的功能（§9-A），但它們**同時也是產品該有的東西** —— 誤加成員要能移除、家人想離開要能帶走自己的資料。放在 TestFlight 之前，是為了讓家人實測的版本就等於送審版本，不要送審前再補一批沒被用過的新功能。

### Phase 2 — 送審與上架（約 2–3 週，含被退重送的緩衝）

1. 隱私政策與支援頁面（GitHub Pages 即可）→ 驗證：兩個 URL 都能公開開啟
2. `PrivacyInfo.xcprivacy`、Info.plist 用途字串、出口合規旗標 → 驗證：Xcode 上傳無警告
3. 審核用 demo 帳號 + 示範家庭資料（有孩子、照片、日記、留言）→ 驗證：**用全新裝置只憑審核備註的資訊，能走完登入到看見內容**
4. App Store Connect 資料：截圖、年齡分級問卷、App Privacy 標籤
5. 送審 → 驗證：通過。**預留 2–3 輪被退的時間**，首次送審的新開發者帳號被要求補件是常態，不是意外

### Phase 3 — 多家庭與體驗
- 一帳號多家庭切換、影片體驗優化（串流/轉檔）、整月照片打包下載（給長輩洗照片）、年度回顧

### Phase 4 —（視需求）NAS，兩條路線擇一

- **4a 冷備份（推薦先做）**：NAS 只跑 MinIO 當備份目的地，定期 S3 sync + `pg_dump`。服務仍留雲端。拿到「資料在自己手上」的保障，但完全不用扛自架 Auth 的維運。
- **4b 完整自架**：NAS 跑 MinIO + self-host Supabase。Storage 換 endpoint 就好，但要額外處理 self-host Auth（自簽 JWT、Sign in with Apple client secret 每 6 個月手動輪替）、Edge Function runtime、APNs 憑證。只有在雲端費用真的痛或有強硬的資料落地需求時才做。
- ⚠️ 上架之後才做自架，難度高於上架前：已上線 app 換後端要處理版本相容（舊版 app 還指著舊 endpoint），且家用網路的可用性要撐得住真實使用者。這是選 4a 的另一個理由。

## 7. 成本估算（雲端階段）

| 項目 | 費用 |
|---|---|
| Apple Developer Program | US$99/年（上 TestFlight/App Store 必要） |
| Supabase Free → Pro | 免費版 1GB 儲存起步；照片量大後 Pro US$25/月含 100GB，超出約 $0.021/GB/月 |
| 流量（egress） | Pro 含 250GB/月，超出另計。長輩會反覆滑同一批照片，這項比想像中容易吃掉 —— **「縮圖與原圖分離、列表只載縮圖」的主要理由是這個，不只是速度** |
| 粗估 | 一家人一年拍 30–50GB（有壓縮），前一兩年 $25/月內可cover 數個家庭 |

⚠️ **這張表只在「使用者是可數的親友」時成立。** 公開上架（listed）後任何人都能註冊並上傳到你付費的 bucket，成本從固定變成隨下載量開放式成長 —— 而你沒有收入。這是 listed 帶來最實際的風險，處理方式見 §10-A。

⚠️ 若日後要讓使用者分攤成本，那筆錢依規定必須走 App 內購買並被 Apple 抽成，本表要整個重算（見 §9-C4）。

發佈方式：**目標是 App Store 正式上架**。TestFlight 作為送審前的內測（最多 10,000 外部測試者，build 90 天過期），不是最終發佈管道 —— 因為 TestFlight 版本會過期、每次更新家人都要重裝，長期給長輩用不實際。listed 或 unlisted 見 §9-C5。

## 8. 風險與備註

- **影片儲存吃錢最兇** → 上傳前壓縮是第一天就要做的事，不是優化項。
- **長輩上手** → 登入流程要最短（Sign in with Apple 一鍵），字體大、操作少。
- **通知洗版** → 沒有彙總的推播會被關掉，關掉之後就再也叫不回來。批次上傳必須合併成一則。
- **隱私** → 全私有 bucket + 簽名 URL + RLS；分享連結與邀請碼一律有期限**且有使用次數上限**。
- **90 天 TestFlight 過期** → 內測期間設 CI 定期出 build；正式上架後此問題自然消失。
- **審核被退是常態不是意外** → 首次送審尤其。Phase 2 已含 2–3 輪緩衝，別把上架日期押在單次通過上。
- **上架後就有真實使用者了** → 資料遷移、破壞性 schema 變更、後端搬家的成本都會跳一級（舊版 app 還指著舊 endpoint）。§5 那些「第一天就做對」的決定，價值在上架後才真正兌現。
- **公開上架 = 成本不再可預測** → 這是 listed 最實際的風險：使用者增加不會帶來收入，只會帶來帳單。儲存額度與用量告警是 MVP 範圍，不是之後再說（§10-A）。
- **公開上架 = 你變成平台方** → 託管陌生人上傳的兒童照片，責任性質與自家使用完全不同（§10-B）。

## 9. 上架 App Store 準備

**上架是既定目標**，所以本節的內容全部在範圍內，差別只在做的時機：A 進 Phase 0–1（影響模型與功能），B 進 Phase 2（送審文書），C 在 Phase 0 就要定案（決策，之後改很痛）。

送審規定以**送審當下**的 App Review Guidelines 為準，Apple 改得比文件快；下列條號僅供定位。真的要送之前，把 Guideline 1.2 與 5.1.1 重讀一次。

### A. 影響資料模型 —— 現在就做（已併入 §3 / §5）

| 項目 | 為什麼不能等 | 落點 |
|---|---|---|
| **A1. UGC 三件套**（Guideline 1.2）：檢舉內容、封鎖使用者、Owner 移除內容，加上「對冒犯性內容零容忍」的使用條款 | 只要有「使用者張貼、他人看得到」的內容就適用，照片和留言都算。「邀請制、沒有陌生人」**不保證免除**。表和 RLS 現在建幾乎免費 | `content_reports`、`blocked_users` |
| **A2. app 內帳號刪除**（Guideline 5.1.1(v)） | 不能只給「寄信給我們」。唯一 Owner 刪帳號會讓整個家庭懸空 → 逼出多 Owner 與轉移機制，這是權限模型層級的改動 | 多 Owner、家庭恆有 ≥1 owner 的 DB 約束 |

承載它們的表與約束在 **Phase 0** 建好，UI 與流程是 **Phase 1 第 7、8 步**。

### B. 送審文書與設定（Phase 2）

- **隱私政策 URL** 與**支援 URL**（皆必填 → 需要一個對外網頁，GitHub Pages 足夠）
- **App Privacy 標籤**：申報收集了照片、聯絡資訊、使用者內容。本 app **明確涉及兒童資料**（生日、照片），政策須寫清楚：由家長自願上傳、僅在私密家庭內可見、如何刪除
- **`PrivacyInfo.xcprivacy`**：申報 required-reason API 的使用理由
- **Info.plist 用途字串**：`NSPhotoLibraryUsageDescription`、相機、推播 —— 寫具體，敷衍會被退
- **EULA**：搭配 A1 的零容忍條款，可用 Apple 標準 EULA 加附一段
- **出口合規**：僅用 HTTPS 屬豁免，設 `ITSAppUsesNonExemptEncryption = false` 免得每次上傳都被問
- **審核用 demo 帳號** —— 邀請制 app 的死穴：審核員登入後沒有家庭、沒有邀請碼，看不到任何功能會被判「無法審核」而退件。須提供可用帳號 + **已有孩子檔案、照片、日記、留言的示範家庭** + 長期有效邀請碼。另外 Sign in with Apple 對審核員偶爾不順，保留 Email OTP 給他們（原本就規劃了，正好）
- **App Store Connect 資料**：截圖、年齡分級問卷、App 名稱／描述。年齡分級問卷會問到「使用者生成內容」與「app 內通訊」，兩項都要誠實勾選，分級可能因此高於 4+

### C. 關鍵決策（皆已定案）

1. **不要放進 Kids Category** ✅ 已定。反直覺但重要：本 app 是「關於小孩」，使用者是大人。進 Kids Category 會觸發嚴格得多的規則（第三方分析受限、外部連結要 parental gate、廣告限制）。目標受眾選成人 —— 內容涉及兒童 ≠ 受眾是兒童。
2. **開發者帳號：個人名義** ✅ 已定。線上刷卡即可註冊，無 D-U-N-S 等待期。
   - **接受的代價**：App Store 頁面的開發者名稱會是法定本名，且被公開索引。評估後認為曝光範圍有限 —— 建立的連結是「你的名字 ↔ 這個 app 存在」，**不是**「你的名字 ↔ 你小孩的照片」（內容全在私密家庭空間內，陌生人下載也看不到）。
   - **已知風險**：Apple 對 organization 帳號要求真正的**法人**（明文不接受商業別名／分支機構），台灣的獨資行號是否適用不確定。若日後需改公司名義，得重新註冊並走 app 轉移 —— **有條件限制、非保證**。判斷是：為一個「可能性」現在養一間公司（設立費 + 每年記帳報稅）不成比例；真成長到那規模時，多半也已因其他理由需要公司，屆時用真實資訊決定。
   - 相關：§10-C 的支援信箱請用**專用地址**，別用私人主信箱 —— 這是本名之外另一個會公開的聯絡資訊。
3. **iPhone + iPad 通用** ✅ 已定。實作影響見 §4：第一天就寫適配式版面。上架時需另備一組 iPad 截圖。
4. **會不會收費 — 刻意延後到決定上架時再定，且延後是安全的。**
   - 理由：唯一會被這題影響的資料模型（`families.storage_quota_bytes` / `storage_used_bytes`）**已經先做了**，額度機制本來就要有。屆時若要收費，是在既有額度上加 IAP 方案，不是改架構。
   - 屆時要留意：向使用者收費**必須走 IAP 並被抽成**，§7 成本表要重算。
5. **listed（公開上架）** ✅ 已定。不申請 unlisted，省掉額外申請與等待，也保留未來讓其他家庭自然使用的空間。
   - 隨之而來的三件事不是選配，見 **§10 公開上架的營運責任**：陌生使用者的成本曝險、內容審查責任、公開評分與客服。
   - **關鍵產品要求**：陌生人下載後必須能自己建立家庭、邀請自己的親友，形成完整體驗。若打開只有一道「請輸入邀請碼」的牆，除了會收到大量一星評價，也有觸犯 Guideline 4.2（最低功能性）被退件的風險。

### D. 名稱查重（送審前）

搜 App Store 有無同名 app、確認無明顯商標衝突。「Little Sprout」是常見詞組，撞名機率不低。上架後改名會丟掉既有連結與安裝基礎，所以在 Phase 2 送審前確認完畢。

## 10. 公開上架（listed）的營運責任

選了 listed，就從「做給家人用的 app」變成「對外營運的服務」。這一節是那個身分轉換帶來的工作，全部屬於 MVP 範圍。

### A. 成本曝險 —— 必須有上限

公開之後任何人都能註冊、建立家庭、上傳照片到**你付費的 bucket**，而你沒有收入。§7 的估算只在「使用者是可數的親友」時成立。三道防線至少要有前兩道：

1. **每家庭儲存額度**（`families.storage_quota_bytes`，預設值取一個你能吸收的數字，例如 2–5GB）。超額擋下上傳並清楚提示。這是硬防線。
2. **Supabase 用量告警**：設定接近方案上限時通知，別靠月結帳單才發現。
3.（備案）**註冊開關**：留一個能快速把新註冊關掉或改為候補的旗標。真的爆量時這是唯一能立刻止血的手段。

額度設多少可以之後調，但**機制要在上架前就在**。上架後才加額度限制，等於要對既有使用者收回已經給出去的東西。

### B. 內容審查責任

公開上架後你是平台方，不再只是自己家的管理員。

- **檢舉要進到你看得到的地方**，不能只通知該家庭的 Owner —— 被檢舉的很可能就是 Owner 本人。需要一個你自己能看的檢舉列表（Supabase Dashboard 手動看就夠，不必做後台）。
- **要有停權能力**：能停掉特定使用者或整個家庭，不需要改程式碼。
- **ToS 要寫清楚**你保留移除內容與終止帳號的權利，以及內容歸屬與刪除方式。
- 這是一個**託管陌生人上傳之兒童照片**的服務，風險性質與「只有自己家人」完全不同。相關的法遵與通報義務因地區而異，在真的開放公開註冊前值得確認一次；至少要具備移除內容、保留必要記錄、以及能配合處理的能力。

### C. 公開評分與客服

- 支援 URL 會真的收到信。用一個**專用信箱**，別用你的私人主信箱（也與 §9-C2 的本名曝光相關）。
- 陌生人下載一個私密家庭 app，體驗不如預期就會留一星，這無法阻止。**App Store 描述要把定位寫在最前面**（「這是給家人的私密相簿，你會建立自己的家庭空間並邀請親友」），把預期設對能減少大部分的失望型評價。
- 不要做「請給我們評分」的彈窗 —— 使用者基數小的時候，一次負評的權重很大。
