# docs/legal — 法務文件（LS-132）

> **這些是草稿，供使用者審閱與（建議）律師審閱，不是法律意見。** 未經使用者核可不得生效、不得公開發佈、不得填入 App Store Connect。
>
> **填入生效日前須逐條核對下方「文本中承諾、但程式尚未落地的項目」對齊表**——表列項目送審時仍未上線者，對應正文必須先改寫。三份正文檔頭各有一行 DRAFT 標記；**正文內不放 HTML 註解錨點**（merge-review R2 實測 `AttributedString(markdown:)` 會把 `<!-- -->` 原樣顯示為文字），待落地標記只在本表，以段落編號定位。正文括號內的票號（例如「（LS-153，待落地）」）是草稿期標記，生效前一併移除——驗收：`grep -n 'LS-[0-9]' docs/legal/privacy-policy.md docs/legal/terms-of-service.md docs/legal/eula-addendum.md` 應為空。

## 三份文件的用途

| 檔案 | 用途 | 誰會看到 | 對應規範 |
|---|---|---|---|
| `privacy-policy.md` | 隱私權政策正式文本（繁中） | App Store 產品頁「隱私權政策」連結（必填 URL）、App 內歡迎頁《隱私權政策》、App 內閱讀器（LS-133） | 個資法第 8 條告知事項；Apple Guideline 5.1.1(i)；App Privacy 標籤（附錄 A） |
| `terms-of-service.md` | 使用條款正式文本（繁中），含 UGC 零容忍條款 | App 內歡迎頁《使用條款》（「登入即表示你同意」）、App 內閱讀器、公開網址 | Apple Guideline 1.2（檢舉／24 小時處理／封鎖／公開聯絡方式）；PLAN §9-A1、§10-B |
| `eula-addendum.md` | 自訂 EULA（以引用方式納入 Apple 標準 EULA＋零容忍與家庭私密附加條款） | App Store Connect「App 資訊 → 授權合約」欄位（若採用）；App Store 產品頁 | PLAN §9-B「EULA：Apple 標準 EULA 加附一段」；Apple 最低條款 |

三份文件互相引用（使用條款 §1.2／§16.5、EULA §一.3／§五.1、隱私權政策 §13），改任何一份的版本號或網址時請同步。

## 需使用者填寫的欄位（placeholder 清單）

所有需使用者決定的欄位以雙中括號 token 標記。核可前請全部替換：`grep -n '\[\[' docs/legal/privacy-policy.md docs/legal/terms-of-service.md docs/legal/eula-addendum.md` 應為空（本 README 自身的清單與說明含 token 字面，不納入掃描）。

| Placeholder | 出現於 | 說明與建議 |
|---|---|---|
| `[[OPERATOR_NAME]]` | 三份皆有 | 服務提供者名稱。開發者帳號為個人名義（PLAN §9-C2），依個資法第 8 條第 1 項第 1 款須具名；建議與 App Store 開發者名稱一致（法定本名） |
| `[[SUPPORT_EMAIL]]` | 三份皆有 | 專用支援信箱（PLAN §10-C：別用私人主信箱）。同時填入 App Store Connect 支援 URL／隱私政策聯絡方式 |
| `[[SUPPORT_URL]]` | 三份皆有 | 法務文件的公開網址根（例如 `https://<user>.github.io/<repo>/legal` 或自有網域 `https://littlesprout.app/legal`）。文內以 `[[SUPPORT_URL]]/privacy`、`/terms` 引用；決定方案後見下節。**現行 `WelcomeView.swift:254,262` 指向 `https://littlesprout.app/legal/terms`／`/privacy`，是佔位網址**——網域決定後 in-app 連結由 LS-133 後續實作票一併改 |
| `[[EFFECTIVE_DATE]]` | 三份皆有 | 生效日期（YYYY-MM-DD）。建議＝使用者核可日或送審日 |
| `[[VENUE_COURT]]` | 使用條款 §14 | 第一審管轄法院，例如「臺灣臺北地方法院」 |
| `[[REPORT_RETENTION]]` | 隱私權政策 §8 | 檢舉紀錄處理完畢後的保存期限，建議「1 年」（稽核與配合調查；PLAN §10-B「保留必要記錄」） |

## 需使用者裁決的事項（非填空）

1. **公開網址方案與網域**：見下節三案。
2. **是否請律師審閱**：兩份主文件涉及個資法告知、消保法責任限制、兒童資料與通報義務（PLAN §10-B：「相關的法遵與通報義務因地區而異，在真的開放公開註冊前值得確認一次」）。建議至少就使用條款 §6.3（通報）、§12（責任限制）、§14（管轄）與隱私權政策 §5（國際傳輸）請律師過目。
3. **EULA 採用方式**（二選一）：
   - **A. 只用 Apple 標準 EULA**（App Store Connect 不填）：零容忍條款由使用條款 §6 承載，歡迎頁「登入即表示你同意」為同意入口；Guideline 1.2 可滿足。最省事；產品頁不顯示授權合約連結。
   - **B. 填自訂 EULA**（貼 `eula-addendum.md` 的 PASTE 區）：產品頁顯示授權合約連結，零容忍在下載前即可見；代價是必須符合 Apple 最低條款（草稿已含第三方受益人、Apple 無維護義務等必要語句，但**建議律師對照 Apple minterms 逐條核對**）。
4. **GDPR**：草稿採「不以歐盟居民為對象」立場（隱私權政策 §12），未做 GDPR 專章。依 GDPR 第 3 條第 2 項，非歐盟業者僅在「向歐盟境內資料主體提供服務」或「監控其行為」時適用；本 App 僅繁中、無歐盟行銷、無追蹤，屬不適用的常見形狀，但**App Store 上架地區若勾選全球，歐盟使用者仍能下載**。若要更保守：送審時把可下載地區限制在臺灣（或亞太），或請律師確認。
5. **照片 EXIF**：目前原檔以原樣上傳（`PickedItemLoader.swift` `loadTransferable(type: Data.self)` → 直接 PUT），EXIF 含拍攝地點會一併保存；草稿已如實揭露（隱私權政策 §2.4）並教使用者自行移除。若使用者希望 App 端上傳前剝除 GPS，屬另票（產品決策＋實作），揭露文字屆時再改。
6. ~~刪除帳號後，您上傳的照片／影片（包括附在日記或相簿中的）要留給家庭，還是一併刪除？~~ **已裁決（2026-09-04，選 (b) 一併刪除，LS-155 落地，R2 補齊伺服器端立即隱藏＋鎖序修正）**：`delete_my_account()`（`20260904070941_delete_account_media.sql`）在同一交易內把呼叫者上傳的每一張 media（含相簿內／日記附帶、含已退出家庭仍留有的 media）軟刪；`media_select` RLS policy（`20260904080921_media_select_hide_deleted.sql`）加 `deleted_at is null`，被軟刪的 media 對家庭其他成員立即在伺服器端消失（日記卡／相簿封面／`fetchMedia` 皆不再回傳），不是只有獨立照片卡經 `feed_items` 消失；`finalize_account_deletion()`（`20260904080802_finalize_account_deletion_media.sql`）重跑一次同樣的軟刪，接住交易提交窗口內在飛上傳的孤兒列；30 天後沿用既有 `purge_expired()` 硬刪＋Storage 入列。文本已改寫為「與日記、留言一樣標記刪除，滿 30 天後永久清除」（隱私 §5／§8，條款 §9.1；§4.5「退出／被移除家庭」是不同動作、不受影響，未改）。

## 文本中承諾、但程式尚未落地的項目（送審前必須對齊）

文件寫的是**送審時**的狀態；下列功能目前在 Backlog／進行中，任何一項若送審時仍未上線，對應段落必須改寫，否則是對使用者的不實陳述、也會被 App Review 退件：

| 文本承諾 | 對應票 | 現況（2026-09-03） |
|---|---|---|
| App 內「設定 → 刪除帳號」兩步流程（隱私 §5 期間、§8「刪除帳號」；條款 §9.1；EULA §四.1）：① RPC 立即——退出家庭／唯一成員的家庭 cascade 刪除／自己的日記相簿留言軟刪／**您上傳的照片與影片（含日記附帶、含已退出家庭仍留有的）一併軟刪並立即停止對家庭成員顯示**／`profiles.deletion_requested_at` 標記；② 登入身分（email／顯示名稱／頭像＝`auth.users`＋`profiles`）與推播裝置代碼於帳號刪除完成時移除；標記資料 30 天內系統自動永久清除 | LS-24（UI）／LS-143（RPC，PR #244）／**LS-151**（Edge Function 以 service_role 刪 `auth.users`）／**LS-153**（30 天自動清除）／**LS-155**（media 軟刪＋伺服器端立即隱藏，PR #270） | LS-143／LS-151 Done；LS-153 QA（SQL 面 `purge_expired()`／清除排程已完成，cron→Edge Function 觸發接線待使用者提供 vault 金鑰）；LS-155 PR #270 review 中（SQL／RLS／文件皆已完成）；LS-24 Backlog，Swift 端尚無「設定 → 刪除帳號」畫面，本表其餘項目待該票補上 |
| 「在 App 內」檢舉（條款 §6.2）、封鎖（§6.4）、Owner 移除內容與處理檢舉（§6.5）、檢舉同時送達平台方；EULA §二.3 | LS-23（UI，設計併入 LS-152）／LS-149（後端） | 表與 RLS 已在（`content_reports`／`blocked_users`）；App 端無呼叫端（`grep -rn -e create_content_report -e blocked_users LittleSprout/` 0 hits）；LS-149 In Progress、LS-23 Backlog |
| 24 小時內處理檢舉（條款 §6.3） | 營運承諾，非程式 | 需有人（使用者本人）看 Supabase Dashboard 的 `content_reports`；建議設 email 或 webhook 提醒，否則 24 小時承諾靠自律 |
| 清除排程：軟刪內容／逾期孩子檔案／刪除帳號後的標記資料 30 天後系統自動永久清除，含照片影片實體檔案與額度對帳（隱私 §5、§8 全段） | **LS-153**（使用者 2026-09-03 裁決：系統自動、不做人工清除；TestFlight 前落地） | Backlog。repo 目前無任何排程（`grep -rni -e pg_cron -e cron.schedule -e purge supabase/` 0 hits）；`docs/API.md:1263` 現行設計**刻意**不硬刪軟刪 `media` 的 Storage 物件；30 天還原邊界只有 `children`（`LS043`，且**無硬刪路徑**、軟刪列對全體成員可讀），`diaries`／`comments`／`albums` 軟刪無時間邊界。正文已依裁決寫「系統自動永久清除（LS-153，待落地）」——**LS-153 未上線前不得填生效日** |
| 推播通知（隱私 §2.5） | LS-22 | 文本已寫「尚未啟用；啟用前不蒐集」——LS-22 上線時把該句刪掉並在 App Privacy 標籤加 Device ID |
| 「重大變更於 App 內通知」（隱私 §13、條款 §15） | 無票 | 目前無 in-app 公告機制；第一版可用 App Store 更新說明＋歡迎頁版本號達成，或另票 |
| 帳號刪除向 Apple 撤銷 token（隱私 §8） | **LS-151**（orchestrator 2026-09-03 已列入票文範圍） | Apple 帳號刪除指引要求以 Sign in with Apple REST API 撤銷；`20260903084231_delete_account.sql`（純 SQL）不做，由 LS-151 的 service_role Edge Function 執行；正文句保留 |
| 刪除單筆內容（照片／日記／留言）UI（隱私 §4.4、§8「刪除單筆內容」；條款 §6.5） | **LS-152**（設定與成員管理畫面群設計票，使用者 2026-09-03 裁決併入） | 後端已在（`set_diary_deleted`／`set_comment_deleted`／`set_album_deleted`、`media.deleted_at`）；App 端無呼叫端（`grep -rn -e set_diary_deleted -e set_comment_deleted -e set_album_deleted LittleSprout/` 只命中 `Errors/AppError.swift` 註解）；唯一有刪除 UI 的是孩子檔案（`Features/Children/EditChildView.swift`）。正文已改為「透過 App 或來信」 |
| 退出家庭 UI（條款 §4.5；隱私 §9） | **LS-152** | 後端已在（`family_members` DELETE policy「任何人可自行退出」，API.md §2）；`Features/SettingsView.swift` 只有「邀請家人」與「登出」。正文已改為「透過 App 或來信」 |
| Owner 移除成員 UI（條款 §4.5、§6.5；隱私 §4.5） | **LS-152** | 後端已在（owner 移除任何人）；`Features/Family/` 無成員清單畫面。正文已改為「有權」 |
| 修改顯示名稱與頭像 UI（隱私 §2.1、§9） | **LS-152** | `profiles` 可 update；`Features/` 無 profile 編輯畫面。正文已改為「透過 App 或來信要求修改」 |
| 留言／愛心／相簿功能本身（條款 §2.1；隱私 §2.4） | LS-22（留言／愛心）；相簿 Phase 1-4（本票未查到專屬票號） | App 端未實作（`create_comment`／`toggle_reaction` 無呼叫端；`Features/AlbumsView.swift` 為 placeholder）；Phase 1 核心功能、送審前必然在——列入只為對齊表完整（R1 n2） |

## 事實核對清單（送審前逐項確認）

- [ ] Supabase 正式專案 region 確為 `ap-southeast-2`（雪梨）——隱私 §5、§6 依 orchestrator 指示撰寫，repo 內無可機械核對的來源；請在 Supabase Dashboard → Project Settings → General 確認
- [ ] 正式站 Email OTP 的 SMTP 供應商確為 Resend（隱私 §6 表）——`supabase/config.toml` 的 `[auth.email.smtp]` 整段註解，正式站設定在 Dashboard；若不是 Resend 請改表列與其隱私政策連結
- [ ] 每家庭儲存額度預設值（條款 §8.1 寫 5 GiB）與正式站 `families.storage_quota_bytes` 預設一致
- [ ] 單檔上限 50 MiB 與格式白名單（條款 §8.2）與 `supabase/migrations/20260823030000_storage_policies.sql` 一致
- [ ] 第三方隱私政策連結全部可開（Supabase／AWS／Apple／Google／Resend）
- [ ] 附錄 A 的 App Privacy 標籤勾選與 App Store Connect 實際勾選一致（LS-147）
- [ ] Info.plist 用途字串（LS-145）與隱私 §10「不允許存取照片圖庫」的描述一致

## 公開網址方案（本票只給方案與步驟，不啟用 Pages）

App Store Connect 的「隱私權政策 URL」與「支援 URL」都必須是公開可開的網址（PLAN §9-B）。三案：

### 案 A：本 repo 的 GitHub Pages，發佈 `docs/` 目錄

- 步驟：Settings → Pages → Build and deployment → Source「Deploy from a branch」→ Branch `main`、Folder `/docs` → Save。之後每次 push 到 `main` 自動更新（docs.github.com「Configuring a publishing source」）。
- 網址：`https://<owner>.github.io/<repo>/legal/privacy-policy`（Jekyll 預設會把 `.md` 轉成 HTML；若不想要 Jekyll，放 `.nojekyll` 並自備 HTML）。
- 優點：零額外 repo、零 workflow，「in-app 顯示與網頁同一份來源」天然成立（LS-132 範圍第 2 點）。
- **缺點**：`docs/` 整個目錄都會變成站台頁面——`PLAN.md`、`API.md`、`COLLABORATION.md` 一起被渲染並可能被搜尋引擎索引。本 repo 目前是**公開** repo（`gh repo view` 2026-09-03：`CLYEH/little-sprout` private=false），這些文件本來就看得到，所以不是保密問題，而是「App 的法務網址底下掛著內部規劃文件」的觀感問題；日後若把 repo 轉 private，Free 方案無法對 private repo 開 Pages。

### 案 B：本 repo 的 GitHub Pages，用 Actions 只發佈 `docs/legal/`

- 步驟：Settings → Pages → Source「GitHub Actions」；加一支 workflow：checkout → 把 `docs/legal/privacy-policy.md` 與 `terms-of-service.md` 轉成 HTML（或 `actions/upload-pages-artifact` 只上傳這兩檔讓 Pages 內建 Jekyll 轉）→ `actions/deploy-pages`。**排除本 README 與 `eula-addendum.md`**——README 含內部裁決與對齊表、EULA 是貼進 ASC 的文本，都不該上公開站台。
- 網址：同案 A 的形狀。
- 優點：同一份來源、只公開法務文件。
- 缺點：多一支 workflow（本 repo 的 CI 慣例是每支 workflow 都要有 gate／自測，屬 harness 票）。

### 案 C：另開公開 repo（例如 `littlesprout-legal`）

- 步驟：新 repo 放 `privacy.md`／`terms.md`／`index.md`，開 Pages（root）。本 repo 的 `docs/legal/` 仍是編輯來源；發佈時複製過去（手動或一支同步 workflow）。
- 優點：與主 repo 的公開性完全解耦；網址乾淨（`https://<owner>.github.io/littlesprout-legal/privacy`）。
- 缺點：兩份副本，要靠流程保證一致（LS-132 驗收「公開網址內容與 repo 一致」需人工或 workflow 比對）。

### 自有網域（`[[SUPPORT_URL]]` 的最終形狀）

三案都可再掛自有網域：Settings → Pages → Custom domain 填 `littlesprout.app`（或子網域 `legal.littlesprout.app`），DNS 端子網域用 CNAME 指到 `<owner>.github.io`、apex 用 A/ALIAS 記錄；**先在 GitHub 設定 custom domain 再改 DNS**，避免子網域被他人接管（docs.github.com「Managing a custom domain」）。若使用者尚未持有 `littlesprout.app`，`WelcomeView.swift` 目前的佔位網址就不能用，需改成 GitHub Pages 預設網址或購買網域。

### 建議

repo 已是公開的，**案 A 最省事且可先上線**（送審前只要一個可開的網址）；在意站台整潔或未來可能轉 private：案 B；有網域且願意另管一個 repo：案 C。三案都不擋日後互轉（只是換網址，App 內連結要跟著改）。

## in-app 閱讀器（LS-133）如何取用

LS-133 票文已定：「SwiftUI 以 bundled markdown 渲染（`AttributedString(markdown:)`）」。兩種取用方式的取捨供該票實作參考：

| 方式 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| **Bundle 內 markdown**（LS-133 現行方向） | build 時把 `docs/legal/privacy-policy.md` 與 `terms-of-service.md`（不含 `eula-addendum.md` 與本 README）複製進 app bundle（xcodegen `project.yml` 加 resource），閱讀器讀本機檔 | 離線可讀、無網路請求、無載入延遲、送審時審核員一定看得到 | 文本更新要發版；App 內版本可能落後公開網址（隱私 §13 承諾「重大變更會在 App 內通知」——兩處版本號不一致時要以公開網址為準並提示更新） |
| **遠端 URL** | 閱讀器用 `WKWebView` 或抓 markdown 後渲染 `[[SUPPORT_URL]]/privacy` | 永遠最新、單一來源 | 需網路；載入失敗要有 fallback；Guideline 5.1.1(i) 要求「App 內容易取得」——網頁失效等於違規；審核時網路環境不可控 |

建議：**bundle 為主、遠端為輔**——閱讀器顯示 bundle 版並附「線上最新版」連結；`docs/legal/*.md` 的檔頭表格保留版本號讓兩邊可比對。`AttributedString(markdown:)` 預設不支援表格與多層清單（`inlineOnlyPreservingWhitespace` 之外的選項也有限），LS-133 實作時要嘛換渲染器，要嘛把檔頭表格改成純段落；本票不動文本格式，留給該票依渲染器決定。另：merge-review R2 實測 `AttributedString(markdown:)`（兩種 parsing option）會把 HTML 註解原樣輸出為可見文字，因此本 PR 起隱私權政策與使用條款**不含任何 HTML 註解**（`eula-addendum.md` 僅有 BEGIN／END PASTE 兩個標記，該檔不進 App bundle，貼進 ASC 時只取標記之間），LS-133 不需剝除；但 `[[…]]` placeholder 與「（LS-nnn，待落地）」草稿標記若殘留同樣會被使用者看到——生效前清空是 LS-133 上線的前提。

## 文本更新流程（LS-132 範圍第 3 點）

1. 在 feature 分支改 `docs/legal/<file>.md`：更新檔頭「版本」「最後修訂」，生效日期改為新版生效日，並在文末「歷史版本」表加一列（一句摘要）。
2. 三份互相引用的版本號同步；PR 走一般流程（development → test → main）。
3. 併入 `main` 後公開網址依所選方案更新；重大變更依隱私 §13／條款 §15 在 App 內通知（機制見上表「尚未落地」列）。
4. 若 in-app 閱讀器採 bundle 版，同一 PR 或下一版 App 更新 bundle。

## 與 PLAN §9 的對照

| PLAN 要求 | 落點 |
|---|---|
| §9-A1 UGC 三件套＋零容忍使用條款 | 使用條款 §6（6.1 禁止內容、6.2 檢舉、6.3 24 小時處理與停權、6.4 封鎖、6.5 Owner 移除、6.6 平台保留權、6.7 申訴）；EULA 附加條款 §二 |
| §9-A2 app 內帳號刪除、唯一 Owner 轉移 | 隱私 §8「刪除帳號」；使用條款 §9.1；EULA §四.1 |
| §9-B 隱私政策 URL／支援 URL | 本 README「公開網址方案」；`[[SUPPORT_URL]]`／`[[SUPPORT_EMAIL]]` |
| §9-B App Privacy 標籤：照片、聯絡資訊、使用者內容；兒童資料由家長自願上傳、僅私密家庭可見、如何刪除 | 隱私附錄 A（標籤對照）；隱私 §4（兒童資料五點承諾＋刪除）；§2.3 |
| §9-B EULA：Apple 標準 EULA 加附零容忍段 | `eula-addendum.md`（自訂 EULA 形式，理由見該檔說明） |
| §9-C1 不進 Kids Category（使用者是大人） | 使用條款 §3.1「不提供給兒童使用」；隱私 §4 前言 |
| §9-C2 個人名義、專用支援信箱 | `[[OPERATOR_NAME]]`／`[[SUPPORT_EMAIL]]` |
| §10-B 平台方看得到檢舉、停權能力、ToS 寫清楚移除與終止權、內容歸屬與刪除方式、通報 | 使用條款 §6.2（檢舉同時送平台方）、§6.3、§6.6、§5.1（內容歸使用者）、§9.2；隱私 §8 |
| §10-A 儲存額度 | 使用條款 §8 |
| §10-C 專用信箱 | `[[SUPPORT_EMAIL]]` |

## 來源

- Apple App Review Guidelines（1.2 使用者生成內容；5.1.1 資料蒐集與儲存）：https://developer.apple.com/app-store/review/guidelines/
- Apple「Offering account deletion in your app」：https://developer.apple.com/support/offering-account-deletion-in-your-app/
- Apple「App privacy details on the App Store」：https://developer.apple.com/app-store/app-privacy-details/
- Apple 標準 EULA：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
- Apple「Provide a custom license agreement」（App Store Connect Help）：https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/
- Apple 開發者 EULA 最低條款：https://www.apple.com/legal/internet-services/itunes/appstore/dev/minterms/
- 個人資料保護法（全國法規資料庫）第 3／8／13／19 條：https://law.moj.gov.tw/LawClass/LawAll.aspx?pcode=I0050021
- 民法第 12 條：https://law.moj.gov.tw/LawClass/LawSingle.aspx?flno=12&pcode=B0000001
- GDPR 第 3 條（適用範圍）：https://eur-lex.europa.eu/eli/reg/2016/679/oj ；非歐盟業者適用性說明：https://gdpr.eu/companies-outside-of-europe/
- Supabase 可用區域：https://supabase.com/docs/guides/platform/regions ；Supabase 與 GDPR：https://supabase.com/docs/guides/security/gdpr-compliance
- GitHub Pages 發佈來源：https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- GitHub Pages 自訂網域：https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
- 專案內部：`docs/PLAN.md` §3、§5、§9、§10；`docs/API.md` §2–§4；`supabase/migrations/20260822120000_init_schema.sql`；`LittleSprout/Features/Auth/WelcomeView.swift:251-262`；`LittleSprout/Services/Diary/PickedItemLoader.swift`
