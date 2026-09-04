# App Review Notes 草稿（LS-146）

PLAN §9-B「審核用 demo 帳號」。本檔是送審時填進 App Store Connect「App Review
Information → Notes」的文案草稿，**送審前需使用者核可**。登入方式已裁決採**方案 B
（帳號密碼登入，2026-09-04）**，見下方「OTP 對審核員的問題」保留的取捨紀錄。

## 帳號

| 角色 | Email | 登入方式 |
|---|---|---|
| Owner（審核用這組登入） | `<REVIEW_OWNER_EMAIL>`（送審時由 orchestrator 執行種子時代入實際地址） | 帳號密碼登入（見下） |
| Member（次要，示範第二成員視角用；帳號僅供示範資料，**審核員不需要、也無法登入**） | `review-demo-member@little-sprout.app` | — |

家庭：「審核示範家庭」（固定 `family_id`，種子腳本
`scripts/ops/review-demo-seed.sh` 建立，冪等可重跑；owner email／密碼用
`--owner-email <REVIEW_OWNER_EMAIL>`／`--owner-password <pw>` 代入，見腳本檔頭
用法）。

**`<REVIEW_OWNER_EMAIL>` 的密碼只寫在 App Store Connect 的 Review Notes，不進
repo、不寫在本檔任何地方。**

## 登入方式：帳號密碼登入（不是 Email 驗證碼，也不是 Sign in with Apple）

App 給一般使用者的登入選項有 Apple／Google／Email 三種；審核帳號另外走一條**只給
審核用**的帳號密碼登入路徑。PLAN §9-B 記錄的理由：Sign in with Apple 對審核員
偶爾不順（審核環境的 Apple ID／Face ID 模擬設定不穩定是已知現象），Email 驗證碼
登入則要求審核員能收到那封信——兩者都不夠可靠，改用帳號密碼登入最直接、不依賴
任何外部環節。

**登入步驟（方案 B，已裁決見下方「OTP 對審核員的問題」）**：歡迎頁三顆登入鈕
（Apple／Google／Email）下方有一行小字「以帳號密碼登入」，點開後輸入
`<REVIEW_OWNER_EMAIL>` 與密碼（密碼見 App Store Connect Review Notes，不寫在
本檔任何地方）即可登入，直接看到示範家庭全部內容。

**前置條件（送審前必須確認）**：這行小字與密碼登入畫面由
[LS-163](https://linear.app/little-sprout-app/issue/LS-163)（設計）／
[LS-164](https://linear.app/little-sprout-app/issue/LS-164)（實作）落地——兩張
票完成並在送審版本裡之前，審核員看不到密碼登入的入口，這份備註就無法照做。

## 示範內容說明

登入後畫面：

- **時間軸**：2 個孩子（小樹、小果）的時間軸卡片，含 18 張照片＋2 支影片（縮圖、
  影片時長徽章）、5 則日記（其中 2 則同時標記兩個孩子，示範「多寶貝標記」功能）。
- **寶貝**：2 個孩子檔案（姓名、生日）。
- **相簿**：目前是畫面預留位置（尚未實作，`AlbumsView.swift` 的
  `ContentUnavailableView`）——這是既有 app 狀態，與本票種子資料無關，審核員點進去
  會看到「相簿」placeholder 文字，屬於正常現況。
- **留言**：日記詳情頁的留言區目前也是畫面預留位置（`DiaryDetailView.swift`
  顯示「留言功能即將推出。」）——**資料庫層面已經有留言與愛心反應**（種子腳本建了
  4 則留言／4 個愛心，掛在照片與日記上），但目前的 UI 還沒有把它們顯示出來；審核員
  點進日記詳情會看到留言區塊存在，但暫時是提示文字而非實際留言列表。這同樣是既有
  app 狀態，不是本票資料的問題。

**送審前待辦**：若「相簿」「留言」這兩塊在送審當下仍是 placeholder，審核備註應該
明講「這兩個區塊的畫面正在開發中」，避免審核員誤判成 app 半成品而以 Guideline 4.2
（最低功能性）退件——這點需要送審前再次確認這兩張票的實際進度（相簿：LS-126 提到
的後續票；留言 UI：目前未見對應票號，需要開票或標記為已知範圍外）。

## 加入家庭（示範邀請碼）

家庭已備妥一組長期有效（3 年）的邀請碼：**`LSDEM7`**。若審核員想示範「加入既有
家庭」流程（而不是用上面的帳號直接登入），可以：
1. 用任一 Email（例如自己的測試信箱）走 Email 驗證碼登入建一個新帳號。
2. 登入後選「我有邀請碼」，輸入 `LSDEM7`。
3. 「審核示範家庭」的 `require_approval` 走表預設值 `true`（`families` 表定義，
   `supabase/migrations/20260823010000_join_approval.sql`）——申請會卡在「等待
   核准」，需要用 owner（`<REVIEW_OWNER_EMAIL>`）帳號登入後在設定裡核准，審核員
   自己無法完成這條路徑的完整體驗。若要示範完整加入流程，建議直接用 owner
   帳號登入即可看到示範家庭全部內容，不需要真的走一次邀請碼加入。

## OTP 對審核員的問題（已裁決：方案 B，2026-09-04）

核心矛盾：Email 驗證碼登入的前提是「審核員能收到那封信」，但審核員用的是自己的
測試環境，收不到寄到示範帳號的信（除非信箱本身是一個審核員能登入查看的真實信箱，
即下方選項 C）。曾列三個方向、各有取捨，**使用者已裁決改採方案 B**：owner 帳號改用
帳號密碼登入，完全繞過寄信環節；密碼只放 App Store Connect 的 Review Notes、不進
repo。以下保留 A／C 兩案原始取捨紀錄：

### 選項 A：固定測試 OTP／測試帳號覆寫（未採用）
讓審核帳號的驗證碼永遠固定（例如 `000000`），繞過真的寄信。
- **需要查證**：Supabase Auth（GoTrue）**沒有**官方公開的「test OTP／test user」
  正式站功能（不同於本機開發用的 Admin API `generate_link`，那是給開發者用
  service_role key 查詢用的，不能交給審核員）。要做到「這一個帳號永遠回固定碼」
  得自己在後端（例如一支只認這個帳號 email 的 Edge Function／RPC 覆寫）加一條
  特例邏輯。
- **代價**：這是額外開發，而且是安全相關的例外路徑（即使限定單一帳號，仍是「繞過
  正常驗證」的後門），上線後要確保這條路徑不會被找到／濫用（例如加時間窗、加
  IP 限制，或送審結束後立刻撤除）。

### 選項 B：Email＋密碼備援（已採用）
給審核帳號另外設一組密碼，用密碼登入取代 OTP。
- **後端**：`scripts/ops/review-demo-seed.sh`（LS-162）已支援用 pgcrypto 的
  `crypt()/gen_salt('bf')` 直接在種子 SQL 內建立密碼帳號（`--owner-password`，
  不帶則自動產生一組只印終端一次的強密碼）。
- **前端**：目前 App 的 `AuthService`／`SupabaseAuthService`
  （`LittleSprout/Services/Auth/`）只有 `signInWithApple`／`signInWithGoogle`／
  `sendEmailOTP`＋`verifyEmailOTP` 四支，沒有 `signInWithPassword`——歡迎頁小字
  連結與密碼登入畫面由 [LS-163](https://linear.app/little-sprout-app/issue/LS-163)
  （設計）／[LS-164](https://linear.app/little-sprout-app/issue/LS-164)（實作）
  落地，**送審前必須確認這兩張票已完成並在送審版本裡**。
- **取捨**：多開一條僅供審核使用的永久登入路徑（留在 app 裡，不像選項 C 是外部
  信箱、完全不動 app 程式碼）；換來的是徹底不依賴任何寄信環節，最穩定、審核員
  永遠不會卡在「收不到信」。

### 選項 C：Magic Link／真實信箱（未採用）
不繞過 email，而是給審核員一個他們真的能登入查看的信箱，審核備註裡連同信箱密碼
一起附上，審核員自己登入該信箱收驗證碼。
- **優點**：不用改任何後端／前端邏輯，最貼近真實使用情境（這就是一般使用者的登入
  流程本身）。
- **代價**：需要一個真實可登入的信箱（例如 Gmail／Workspace），且審核備註裡要附
  這組信箱的登入密碼，等於多一個需要保護的憑證；換信箱或密碼輪替時得同步更新
  種子與這份備註。
- **未採用原因**：2026-09-04 使用者改採方案 B——登入路徑完全在我們自己的 app 與
  資料庫掌控內，不依賴任何外部信箱服務。

**送審後待辦**：審核結束後輪替 `<REVIEW_OWNER_EMAIL>` 帳號的密碼（App Store
Connect Review Notes 裡的密碼視同已對審核員曝光過的憑證，審核流程走完就該換掉）。

## 隱私權政策／支援 URL

（待補：PLAN §9-B「B. 送審文書與設定」要求的隱私政策 URL 與支援 URL，尚未有
對外網頁，不在本票範圍，留給 Phase 2 送審文書票。）
