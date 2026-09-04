# App Review Notes 草稿（LS-146）

PLAN §9-B「審核用 demo 帳號」。本檔是送審時填進 App Store Connect「App Review
Information → Notes」的文案草稿，**送審前需使用者核可**（尤其是下方「OTP 對審核員的
問題」一節——那是產品裁決，本票只列選項不下決定）。

## 帳號

| 角色 | Email | 登入方式 |
|---|---|---|
| Owner（審核建議用這組） | `<REVIEW_OWNER_EMAIL>`（送審時由 orchestrator 執行種子時代入實際地址） | Email 驗證碼（見下） |
| Member（次要，示範第二成員視角用） | `review-demo-member@little-sprout.app` | 同上 |

家庭：「審核示範家庭」（固定 `family_id`，種子腳本
`scripts/ops/review-demo-seed.sh` 建立，冪等可重跑；owner email 用
`--owner-email <REVIEW_OWNER_EMAIL>` 代入，見腳本檔頭用法）。

**`<REVIEW_OWNER_EMAIL>` 的密碼只寫在 App Store Connect 的 Review Notes，不進
repo、不寫在本檔任何地方。**

## 登入方式：Email 驗證碼（不是 Sign in with Apple）

App 的登入選項有 Apple／Google／Email 三種。PLAN §9-B 記錄的理由：Sign in with
Apple 對審核員偶爾不順（審核環境的 Apple ID／Face ID 模擬設定不穩定是已知現象），
Email 驗證碼登入不需要任何第三方帳號設定。

**登入步驟（方案 C，已裁決見下方「OTP 對審核員的問題」）**：審核員登入
`<REVIEW_OWNER_EMAIL>` 這個信箱（密碼見 App Store Connect Review Notes）→ 回到
app 選「使用 Email 登入」、輸入同一組 email → 10 分鐘內信箱會收到 6 位數驗證碼，
回 app 輸入完成登入。

**已知限制**：驗證碼有效期 10 分鐘，過期需要重新索取（畫面上會有「重新寄送」倒數
計時）。

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

## OTP 對審核員的問題（已裁決：方案 C，2026-09-04）

核心矛盾：Email 驗證碼登入的前提是「審核員能收到那封信」，但審核員用的是自己的
測試環境，**收不到寄到示範帳號原本預設網域的信**（除非這個信箱本身是一個審核員
能登入查看的真實信箱）。曾列三個方向、各有取捨，**使用者已裁決採方案 C**：給審核員
一個他們真的能登入查看的信箱，密碼只放 App Store Connect 的 Review Notes、不進
repo。以下保留 A／B／C 三案原始取捨紀錄：

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

### 選項 B：Email＋密碼備援（未採用）
給審核帳號另外設一組密碼，用密碼登入取代 OTP。
- **需要新開發**：目前 App 完全沒有密碼登入路徑——`AuthService`／
  `SupabaseAuthService`（`LittleSprout/Services/Auth/`）只有
  `signInWithApple`／`signInWithGoogle`／`sendEmailOTP`＋`verifyEmailOTP` 四支，
  没有 `signInWithPassword`。要做這個選項，需要新增一個（可能只給審核帳號用、
  或藏在設定裡的）密碼登入畫面與呼叫路徑——這是產品要不要為審核多開一條永久
  登入路徑的決定，不是小改動。

### 選項 C：Magic Link／真實信箱（已採用）
不繞過 email，而是給審核員一個他們真的能登入查看的信箱（`<REVIEW_OWNER_EMAIL>`，
使用者提供的 Gmail／Workspace 信箱地址），審核備註裡連同信箱密碼一起附上，審核員
自己登入該信箱收驗證碼。
- **優點**：不用改任何後端／前端邏輯，最貼近真實使用情境（這就是一般使用者的登入
  流程本身）。
- **代價**：審核備註裡要附這組信箱的登入密碼，等於多一個需要保護的憑證——密碼
  只寫在 App Store Connect 的 Review Notes，不進 repo、不寫在本檔任何地方。

**送審後待辦**：審核結束後輪替 `<REVIEW_OWNER_EMAIL>` 信箱密碼（App Store Connect
Review Notes 裡的密碼視同已對審核員曝光過的憑證，審核流程走完就該換掉）。

## 隱私權政策／支援 URL

（待補：PLAN §9-B「B. 送審文書與設定」要求的隱私政策 URL 與支援 URL，尚未有
對外網頁，不在本票範圍，留給 Phase 2 送審文書票。）
