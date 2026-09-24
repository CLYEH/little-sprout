#if DEBUG
/// LS-95：≥44pt 點擊目標機械 gate 用的畫面選擇鍵值。
///
/// XCUITest 跑在跟被測 app 分離的獨立行程，`LittleSproutUITests` 沒辦法 `import LittleSprout`
/// 直接引用 app target 的型別（跟 `LittleSproutTests` 這種同行程的 unit test 不一樣）——兩邊
/// 只能靠字串常數溝通：app 這邊（`TapTargetGateHarness.swift`）讀 launch environment 決定顯示
/// 哪個畫面，UI test 那邊寫入同一個字串當作 launch environment 值。這份 rawValue 定義因此同時
/// 被兩個 target 的 sources 收錄（見 project.yml），值只需要改一處。
///
/// merge-review R1 I1：整支 `#if DEBUG` 圍住——本來沒有圍欄，Release build 會編進一個永遠用
/// 不到的 enum（`TapTargetGateHarness` 已經整支 `#if DEBUG`，只在 DEBUG 引用它）。兩個 target
/// 的 Debug 組建都定義了 `DEBUG`（`xcodebuild -showBuildSettings` 實測 `LittleSproutUITests`
/// 的 Debug 組態一樣有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`，繼承自 project 層級），
/// 加圍欄不影響 UI test target 編譯。
enum TapTargetGateScreenName: String {
    case otpVerification = "OTPVerificationView"
    case settings = "SettingsView"
    // LS-188：`.settings` 這個既有 case（`familyStore.preview(withFamily:)`＋
    // `childrenStore: .preview()`）現在會經由 `SettingsView` 新增的 `.task` 補查角色，落到
    // `PreviewChildAPIClient.fetchMyRole` 固定回傳的 `.owner`——五區＋「檢舉紀錄」（Owner
    // 限定列）都蓋得到。這個變體額外把角色釘死在 `.member`（`ChildrenStore
    // .seedRoleForPreview`），讓 `SettingsViewTests` 能斷言「檢舉紀錄」列在 member 視角
    // 不會出現，不只測 owner 那一半。
    case settingsMemberRole = "SettingsViewMemberRole"
    // LS-188 merge-review R1 B1：iPad（regular 寬度）互動回歸專用——見
    // `TapTargetGateHarness.settingsRegularHost` 文件註解。
    case settingsRegular = "SettingsViewRegular"
    // merge-review R1 M5：`DiaryEditorView` 原本具名排除在 tap-target-exemptions.txt，理由
    // 「多步驟表單流程」不成立——初始態不需要任何 seeding（`PreviewDiaryAPIClient`／
    // `PreviewMediaUploadService` 已經是 `#Preview` 在用的假 client，`ChildrenStore.preview()`
    // 同理），初始態本身就有 5 顆可點元件會被量到（取消鈕／新增照片 cell／日期欄位／歸屬欄位／
    // 發佈鈕）——改註冊進 harness，讓這個畫面之後的回歸能被機械 gate 抓到。
    case diaryEditor = "DiaryEditorView"
    // LS-169：頭像欄從「視覺佔位、刻意不掛互動」改成真的可點的 `PhotosPicker` 觸發鈕——
    // 取代 `tap-target-exemptions.txt` 原本「多步驟表單流程」的排除理由（那個理由當初就
    // 站不住腳：`.preview()` 系列本來就能免登入建構出這個畫面，同 `diaryEditor` 這一支的
    // 先例），初始態（未選圖）就有代表性：頭像欄／姓名欄／生日欄／建立鈕／之後再說鈕
    // 五顆可點元件都不需要任何 seed 資料。
    case createChild = "CreateChildView"
    // LS-126 delta 復審 m2：`TimelineView` 整體仍在 `tap-target-exemptions.txt`（日分組卡片／
    // 捲底載入需要多筆假資料與捲動狀態才有代表性）——但 Header 停靠的「新增回憶」建立鈕不看
    // 任何 feed 資料，`.preview()` 空狀態就會渲染，是這個畫面唯一「不需要 seed 就有代表性」
    // 的可點元件，量測成本低，值得單獨拉一個 case 出來蓋。
    case timelineDefaultState = "TimelineViewDefaultState"
    // LS-343：390pt（iPhone 12 Pro 實機回報寬度）／375pt（iPhone SE／16e）窄寬度變體——不是
    // 獨立檔案，不需要另外具名排除（同 `.settingsMemberRole`／`.uploadQueueSheetNormal` 等既有
    // 變體 case 的先例）。`.frame(width:)` 直接鎖住外層容器寬度，不需要真的換模擬器機型即可
    // 重現／釘住「窄寬度下 Header 兩顆鈕被換行壓縮」這個 wiring 缺陷（同 `.legalDocument
    // NarrowContainer` 的既有 320pt 窄容器 proxy 手法，見 `TapTargetGateHarness+Legal.swift`
    // 文件註解）。
    case timelineHeaderNarrow390 = "TimelineViewHeaderNarrow390"
    case timelineHeaderNarrow375 = "TimelineViewHeaderNarrow375"
    // LS-343：`ViewThatFits` 決策無關的補強量測——把兩顆鈕各自塞進遠小於自然寬度的
    // `.frame(width: 60)`，直接驗證 `lineLimit(1)`／`fixedSize(horizontal:)` 本身有沒有
    // 生效（見 `TapTargetGateHarness+Timeline.swift` 的 `timelineButtonCompressionProxyHost`
    // 文件註解，說明為什麼需要繞開 `headerRow` 另外測這個）。
    case timelineButtonCompressionProxy = "TimelineViewButtonCompressionProxy"
    // LS-165：`AlbumsView` 從 `ContentUnavailableView` 佔位換成正式內容——原本
    // `tap-target-exemptions.txt` 的排除理由（「placeholder 畫面，無互動元件」）不再成立，
    // 改直接註冊。rawValue 逐字等於檔名（`AlbumsView`），`tap-target-registry-check.sh` 認得
    // 這個形狀，不需要額外在排除清單具名。空狀態（`.preview()` 預設無相簿）就有代表性：
    // Header 停靠的「新增相簿」建立鈕不看任何相簿資料，同 `.timelineDefaultState` 的既有
    // 判準；卡片列表本身（沖印品縮圖／NavigationLink）需要多筆假相簿與捲動狀態才有代表性，
    // 留給 QA 模擬器實測（票文驗收要求的模擬器截圖對稿已覆蓋）。
    case albumsDefaultState = "AlbumsView"
    // LS-165：`AlbumSummaryCardView` 排除清單的理由寫「導覽由外層 AlbumsView 的
    // NavigationLink 負責，該處已走 tap-target-check 涵蓋的互動路徑」——這句話要成立，
    // 需要至少一個註冊畫面真的渲染出有相簿的列表，不能只靠空狀態（`.albumsDefaultState`）。
    // 這個 case 補上這個缺口：`AlbumsStore.seedForPreview` 三張涵蓋 1–9／10–49／50+ 三個
    // 厚度分級的假相簿，量測每張卡片（`NavigationLink` 整卡是唯一 tap target）的點擊區。
    case albumsPopulatedState = "AlbumsViewPopulatedState"
    // LS-165：`CreateAlbumView`（新增相簿 sheet）同 `createChild` 的既有理由——初始態
    // 不需要任何 seed 資料（`AlbumsStore.preview()`／`ChildrenStore.preview()` 已是
    // `#Preview` 在用的假 client），姓名欄／寶貝標記欄／建立鈕三顆可點元件一開畫面就有代表性。
    case createAlbum = "CreateAlbumView"
    // LS-166：`AlbumDetailView` 從 LS-165 的最小佔位（`ContentUnavailableView`）換成正式內容，
    // 取代 `tap-target-exemptions.txt` 原本的具名排除（同 `albumsDefaultState` 的既有理由）。
    // owner 視角涵蓋 Nav Row（自畫返回鍵／更多選單）＋Action Bar（加入照片）三顆可點元件；
    // 照片牆本身無互動元件（`AlbumPhotoPrintCell` 具名排除），空狀態就有代表性。
    case albumDetailOwner = "AlbumDetailView"
    // LS-166：member 視角——「更多」選單依 Notes `OHMPk` 僅 owner 可見，這個變體不是獨立
    // 檔案，不需要另外具名排除（同 `.settingsMemberRole` 既有先例）。
    case albumDetailMember = "AlbumDetailViewMemberRole"
    // LS-166：「編輯相簿名稱」sheet——初始態（標題已預填）不需要任何 seed 資料，同
    // `createAlbum` 的既有理由。
    case editAlbum = "EditAlbumView"
    // LS-166：相簿詳情「有照片」（12 張，真實比例混排）——不用來做逐元件 tap target 量測
    // （同 `.diaryCardVideoBadges`／`.deleteAccountInProgress` 既有先例），純粹借用「launch
    // environment 指定畫面」這條通道供 QA／設計對稿截圖。
    case albumDetailPopulated = "AlbumDetailViewPopulated"
    // LS-166 票文範圍 3：34 張壓測，同上不用於逐元件量測。
    case albumDetailStress = "AlbumDetailViewStress"
    // LS-136：`SectionTabBar`（`cmp/Tab Bar` 全字級純 icon）本身不是 `Features/**/*View.swift`
    // （住在 `Navigation/`），`tap-target-registry-check.sh` 不會強制要求註冊，但票文 scope 4
    // 明確要求「TapTargetGateHarness 註冊 Tab Bar 預設態（四顆 ≥44pt）」——直接掛完整的
    // `AuthenticatedRootView`（compact），一次覆蓋 tab bar 四顆 cell 的點擊區，也是
    // `TabRootHeadingTests`（entry-conditions.md ⑬）共用的同一個 host。
    case sectionTabView = "SectionTabView"
    // LS-344 R2（merge-review R1 M1 回歸測試用）：`RootView.SectionSplitView`（iPad regular
    // 寬度，sidebar＋detail）——`.sectionTabView` 強制 compact，測不到 detail 欄收起側邊欄後
    // 是否還有路可以回其他分頁。
    case sectionSplitView = "SectionSplitView"
    // LS-370：同 `.sectionSplitView`，但 `childrenStore` seed 兩個寶貝——`ChildrenManagementViewIPadTests`
    // 要點選左欄寶貝列、確認右欄詳情出現（`PreviewChildAPIClient.listChildren` 固定回 `[]`）。
    case sectionSplitViewWithChildren = "SectionSplitViewWithChildren"
    // merge-review R1 M1 回歸測試用：`.sectionTabView` 的 `timelineStore` 是空狀態，時間軸
    // 沒有任何日記卡可點，無法真的 push 進 `DiaryDetailView`——這個變體額外 seed 一筆日記
    // （`TimelineStore.seedForPreview(entries:)`，`TimelineStore.swift` DEBUG-only），讓
    // `SectionTabBarPushRegressionTests` 能真的點卡片 push 進去，驗證自訂 Tab Bar 在 push 後
    // 消失（不只驗 `DiaryEditorView` 那條 push 路徑）。
    case sectionTabViewWithDiary = "SectionTabViewWithDiary"
    /// merge-review `443ec21a` §3：不是點擊目標測試，是借用同一套「launch environment 指定
    /// 畫面」機制餵 `DiaryCardVideoBadgeGeometryTests` 量真實 frame（a11y tree 讀得出文字，
    /// 讀不出像素——這正是本輪 FAIL 的根因，見該測試檔文件註解）。沿用這裡而不是另開一套
    /// 平行機制：兩個 target 之間本來就只有這一條「XCUITest 指定畫面」通道。
    case diaryCardVideoBadges = "DiaryCardVideoBadges"
    // LS-167：上傳佇列 sheet（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`）——相簿詳情
    // 的「加入照片」入口留給 LS-166（尚未實作），這裡借同一招掛一個代表性樣本（三群、LS002
    // 置頂、有／無進度百分比的上傳中列都在），讓這個新元件在有真正入口之前就能被機械 gate
    // 與 UITest 覆蓋，不必等 LS-166。
    case uploadQueueSheet = "UploadQueueSheetView"
    // merge-review R3 M1：`previewSample()` 一次展示所有狀態，`summarySection` 裡永遠有
    // 續傳橫幅或重試列撐滿寬度，測不出「完全沒有撐寬元件時整塊被置中」這個回歸（reviewer
    // 在生產常態下量到群標題 x=119.3，應為 24）。這個 case 掛 `previewNormalSample()`（無
    // 失敗、無續傳橫幅、`uploading` 不帶百分比），專門讓機械 gate／UITest 覆蓋這個常態。
    case uploadQueueSheetNormal = "UploadQueueSheetViewNormal"
    // LS-303：匯入整理頁（Import 01/02/03）——`plan:` 入口專為 harness／preview 準備，固定
    // fixture（23＋5＋3 張日期不明群）即有代表性；下一 case 為 limited-library 疊加態（同一
    // fixture，`accessState: .limited` 額外渲染 06a banner）。
    case importOrganizeDefault = "ImportOrganizeView"
    case importOrganizeLimited = "ImportOrganizeViewLimited"
    case importPermissionDenied = "ImportPermissionDeniedView"  // 06b 拒絕權限空狀態
    // LS-304：04 匯入進度頁——固定樣本涵蓋沒有成功／正在進行／已完成三群＋整批進度卡，
    // 「取消匯入」／「在背景繼續，關閉視窗」／逐列重試／整批重試皆有代表性。
    case importProgressDefault = "Import04ProgressView"
    // LS-304：04 進度頁疊 04b 取消整批確認——「繼續匯入」／「取消匯入」雙鈕另外量測。
    case importProgressCancelConfirm = "Import04ProgressViewCancelConfirm"
    // LS-304：05 完成摘要頁——固定樣本含失敗列，「回到時間軸」／「重試失敗項」／逐列重試
    // 皆有代表性。
    case importSummaryWithFailures = "Import05SummaryView"
    // LS-319：05 完成摘要頁疊「寶貝標記未完成」——同 `.albumDetailPopulated`／
    // `.albumDetailStress` 既有先例，變體態用不以 "View" 結尾的 rawValue，registry gate
    // 只要求基底檔名（上面那個 case）至少出現一次。
    case importSummaryWithMarkingFailure = "Import05SummaryViewMarkingFailure"
    // LS-164：帳號密碼登入畫面（審核帳號用）——初始態不需要任何 seed 資料（`.preview()`
    // 免登入即可建構，同 `createChild`／`createAlbum` 的既有理由），Email／密碼欄與登入鈕
    // 一開畫面就有代表性。
    case passwordSignIn = "PasswordSignInView"
    // LS-191：法務文件 in-app 檢視 sheet——初始態（載入後）不需要任何 seed 資料，`kind:
    // .termsOfService` 固定讀 bundled markdown，Head 標題／Footer 關閉鈕一開畫面就有代表性。
    case legalDocumentSheet = "LegalDocumentSheet"
    // R4（merge-review R3 889164c6 F1）：強制走 iPad 自適應內距分支＋320pt 窄容器，
    // 不需要真的是 iPad 裝置——在 iPhone 專屬機上就能重現／釘住 wiring 缺陷。
    case legalDocumentNarrowContainer = "LegalDocumentNarrowContainer"
    // LS-190：EULA 同意頁——`EULAStore.preview(shouldPresent: true)` 同步灌狀態，不需要真的
    // 打網路即有代表性（同 `.legalDocumentSheet` 的既有理由）。
    case eulaConsent = "EULAConsentView"
    // LS-190 R2（merge-review R1 M1）：刪除日記確認 sheet——`DiaryDetailView` 沒有稿面內容
    // 操作表列（稿 `vzYXz` 沒有這一列），入口與作者／owner 判斷留給 LS-189，這裡直接掛
    // `DiaryDeleteConfirmationSheet` 本體，用 `TapTargetGateHarness.DismissableSheetHost`
    // （真的 `@State` 綁定，不是 `.constant(true)`——見該檔文件註解，R2 informational-2
    // 訂正舊註解的錯誤描述）把 sheet 頂出來。
    case deleteDiaryConfirmation = "DeleteDiaryConfirmation"
    // LS-190：刪除留言確認 sheet——LS-245 訂正：真實產品入口現在是 LS-218
    // `CommentsSheetView+Actions.swift` 留言列操作表的「刪除」；這支 host 是不依賴留言清單種子
    // 資料、gate／UITest 可直接覆蓋的固定入口，同上一個 case 的理由。
    case deleteCommentConfirmation = "DeleteCommentConfirmation"
    // LS-190：票文驗收「首次登入 → EULA 出現 → 同意 → 進時間軸」——這個 case **不**用來做
    // 逐元件 tap target 量測（`TapTargetGateTests.swift` 沒有對應 test method，同 `.welcome`／
    // `.sectionTabViewWithDiary` 的既有先例），純粹借用「launch environment 指定畫面」這條既有
    // 通道，讓 UITest 能直接啟動到「EULA 已出現、按下同意會換到主畫面」這個組裝狀態，不需要
    // 真的登入。
    case eulaConsentToTimelineFlow = "EULAConsentToTimelineFlow"
    // LS-164：`WelcomeView` 本身仍留在 `tap-target-exemptions.txt`（Apple 官方
    // `SignInWithAppleButton` 量測意義有限，理由未變）——這個 case **不**用來做逐元件 tap
    // target 量測（`TapTargetGateTests.swift` 沒有對應 test method），純粹借用「launch
    // environment 指定畫面」這條既有通道，讓 `PasswordSignInUITests` 能直接啟動到歡迎頁，
    // 測「小字連結存在且 tap 能導覽到帳密登入畫面」這條票文驗收，不需要真的登入或建立家庭。
    case welcome = "WelcomeView"
    // LS-192：02 顯示名稱與頭像編輯——從 `ContentUnavailableView` 佔位換成正式內容，取代
    // `tap-target-exemptions.txt` 原本的具名排除（同 `albumsDefaultState` 的既有理由）。初始態
    // （`.preview(withFamily:)` 免登入即可建構）就有代表性：頭像欄（PhotosPicker 觸發鈕）／
    // 姓名欄／「儲存變更」主鈕三顆可點元件都不需要額外 seed 資料。
    case profileEdit = "ProfileEditView"
    // LS-192：03 家庭成員——同上，換掉原本的具名排除。用 `FamilyStore.seedMembersForPreview`
    // 佈置一位 owner（自己）＋一位 member，量測 Owner 視角「…」選單與「退出家庭」鈕；member
    // 視角（看不到「…」選單）留給 QA 模擬器實測（票文驗收要求的截圖對稿已覆蓋）。
    case familyMembers = "FamilyMembersView"
    // LS-193：刪除帳號流程——`DeleteAccountFlowView` 從 LS-188 的最小佔位（`Content
    // UnavailableView`）換成正式內容，取代 `tap-target-exemptions.txt` 原本的具名排除。三分流
    // （04a／04b／04d）各用不同的 `FamilyStore` 種子資料同步佈置（見
    // `TapTargetGateHarness+DeleteAccount.swift`），04e／04g／04h 直接掛對應子畫面；04f 無互動
    // 元件不需要量測。
    case deleteAccountGeneralMember = "DeleteAccountFlowView"
    case deleteAccountMustTransfer = "DeleteAccountFlowViewMustTransfer"
    case deleteAccountSoleMember = "DeleteAccountFlowViewSoleMember"
    case deleteAccountFinalConfirm = "DeleteAccountFlowViewFinalConfirm"
    /// 04f 進行中——純顯示、無互動元件，不進 `TapTargetGateTests`（見
    /// `TapTargetGateHarness+DeleteAccount.swift` `deleteAccountInProgressHost` 文件註解），
    /// 借這條既有「launch environment 指定畫面」通道純粹是為了截圖對稿（同 `.diaryCardVideoBadges`
    /// 的既有先例：不是點擊目標測試，只是借用同一套機制）。
    case deleteAccountInProgress = "DeleteAccountFlowViewInProgress"
    case deleteAccountCompleted = "DeleteAccountFlowViewCompleted"
    case deleteAccountFailed = "DeleteAccountFlowViewFailed"
    // LS-189：內容操作表（05）——三動作皆顯示的示範態（`WgbNc`），`.preview()` 免登入即可
    // 建構，不需要任何 seed 資料。
    case contentActionsSheet = "ContentActionsSheet"
    // LS-189：檢舉原因（05b）——六個原因列＋送出／取消鈕。
    case reportReasonSheet = "ReportReasonSheet"
    // LS-189 R2（merge-review R1 B4）：檢舉送出後拿到 LS026（target 存在但屬於別的家庭）——
    // 「這則內容已經不存在了」專屬文案＋單一「關閉」變體，見 `ReportReasonSheet.isTargetGone`
    // 文件註解。同 `.reportInboxResolveError` 的既有理由，不用來做逐元件 tap target 量測。
    case reportReasonSheetTargetGone = "ReportReasonSheetTargetGone"
    // LS-189：封鎖確認（05d）。
    case blockConfirmSheet = "BlockConfirmSheet"
    // LS-189：Owner 移除內容確認（05e）。
    case ownerRemoveContentConfirmSheet = "OwnerRemoveContentConfirmSheet"
    // LS-189：封鎖名單（06）——從 `ContentUnavailableView` 佔位換成正式內容，取代
    // `tap-target-exemptions.txt` 原本的具名排除（同 `albumsDefaultState` 的既有理由）。
    case blockList = "BlockListView"
    // LS-189：檢舉收件匣（07，待處理列＋三動作）——同上，換掉原本的具名排除。
    case reportInbox = "ReportInboxView"
    // LS-189：檢舉收件匣·沒有待處理（07b 空狀態）——變體，不是獨立檔案，不需要另外具名排除
    // （同 `.settingsMemberRole`／`.uploadQueueSheetNormal` 等既有變體 case 的先例）。
    case reportInboxEmpty = "ReportInboxViewEmpty"
    // LS-189 R2（merge-review R1 B1）：「這則沒問題」失敗變體——`PreviewSafetyAPIClient
    // .markResolvedError` 種一個 42501，讓 `markReportResolved` 一定 throw，驗證錯誤訊息正確
    // 顯示（原本的 bug：`resolvingReportID` 跟 `actionError` 綁在一起，`defer` 同步清掉判斷
    // 條件，錯誤字永遠不會出現，見 `ReportInboxView.swift` 文件註解）。不用來做逐元件 tap
    // target 量測（同 `.welcome`／`.eulaConsentToTimelineFlow` 等既有先例），純粹借用「launch
    // environment 指定畫面」這條通道跑功能回歸。
    case reportInboxResolveError = "ReportInboxViewResolveError"
    // LS-189：`DiaryDetailView` 導覽列「⋯」內容操作表入口——從最小佔位換成正式內容（帶一篇
    // 日記＋作者身分），取代原本「需要 TimelineStore 帶一篇日記與附照資料才有代表性」的具名
    // 排除，同 `.blockList`／`.reportInbox` 的既有理由。
    case diaryDetail = "DiaryDetailView"
    // LS-189：`DiaryDetailView`「⋯」入口的「自己的內容」變體——作者故意種成跟
    // `familyStore.ownerUserID` 相同的 uuid，`contentActions(...)` 只會回傳 `.deleteOwn`，
    // 用來覆蓋「操作表『刪除』→ 既有 `DiaryDeleteConfirmationSheet`」這條分流（同 `.diaryDetail`
    // 的既有理由，不是獨立檔案，不需要另外具名排除）。
    case diaryDetailOwnContent = "DiaryDetailViewOwnContent"
    // LS-189 R2（merge-review R1 m2）：`childrenStore.myRole` 還沒到齊（未呼叫
    // `seedRoleForPreview`，`ChildrenStore.preview()` 預設 nil）——驗證「更多操作」在這個狀態
    // 下是 disabled，不是可點但按下去沒反應。同 `.reportInboxResolveError` 的既有理由，不用來
    // 做逐元件 tap target 量測（disabled 按鈕本來就不該被量測熱區）。
    case diaryDetailRoleNotReady = "DiaryDetailViewRoleNotReady"
    // LS-246（票文範圍 1）：同 `.diaryDetail`，但瀑布流帶一支真的「可播放」影片格
    // （`MasonryPhotoWallView.isPlayableVideo`）——`DiaryDetailCommentsUITests`／
    // `ContentActionsUITests` 既有的兩支「連續觸發兩來源仍能各自呈現」測試只涵蓋留言 sheet／
    // 內容操作表這一組，這個變體讓「影片 fullScreenCover」也能被同一種手法覆蓋（見
    // `TapTargetGateHarness+Safety.swift` 的 `diaryDetailWithVideoHost` 文件註解）。不是獨立
    // 檔案，不需要另外具名排除（同 `.diaryDetailOwnContent` 既有先例）；不用來做逐元件 tap
    // target 量測（瀑布流格熱區大小取決於 `MasonryLayout.place` 算出的版面，不是本票範圍，同
    // `.diaryCardVideoBadges`／`.albumDetailPopulated` 既有先例）。
    case diaryDetailWithVideo = "DiaryDetailViewWithVideo"
    // LS-216：時間軸互動列（`InteractionRow`）——三種卡片（日記／相簿／照片）底部各有
    // Like Toggle／Count Zone／Comment Button 三顆按鈕，共 9 顆。刻意不 seed `familyStore`
    // （同 `sectionTabViewWithDiaryHost` 文件註解點名的既有陷阱：seed 了會讓 `TimelineView`
    // 的 `.task` 真的打 `PreviewTimelineAPIClient.fetchTimelinePointers`，固定回傳 `[]`
    // 蓋掉種好的 `timelineStore.entries`），改直接種 `timelineStore.familyID`（LS-216
    // `seedForPreview(entries:familyID:)` 新參數）讓 `InteractionRow` 的按讚／按讚名單
    // 呼叫有 `familyID` 可用。
    case timelineInteractionRow = "TimelineViewInteractionRow"
    // LS-217：推播權限前置說明頁——初始態（`PushNotificationStore.preview()` 預設
    // `.notDetermined`）不需要任何 seed 資料即有代表性，同 `.createChild` 等既有先例。
    case pushPreprompt = "PushPrepromptView"
    // LS-217：設定頁「推播通知」列——`.denied`／`.authorized` 兩個變體，不是獨立檔案（同
    // `.settingsMemberRole`／`.uploadQueueSheetNormal` 等既有變體 case 的先例），用來覆蓋
    // `.settings`（預設 `.notDetermined`）之外的另外兩種授權狀態，讓三態文案與點擊行為都能被
    // UITest／tap-target-check 覆蓋。
    case settingsPushDenied = "SettingsViewPushDenied"
    case settingsPushAuthorized = "SettingsViewPushAuthorized"
    // LS-218：留言 sheet——有留言的常態（3 則，同 `FiBvh` 稿面示範筆數），涵蓋輸入列（欄位＋
    // 送出鈕）與逐則留言列（`Button`，點下去開操作表）。空狀態／錯誤態／載入更早只靠這三顆
    // 元件無法一次覆蓋，留給 `CommentsSheetUITests` 各自的變體覆蓋（同 `.uploadQueueSheet`／
    // `.uploadQueueSheetNormal` 只挑一個常態進 tap-target 量測、其餘變體交給功能性 UITest 的
    // 既有分工）。
    case commentsSheet = "CommentsSheetView"
    // LS-218：空狀態（`TnxXE`）——不用來做逐元件 tap target 量測（同 `.reportInboxEmpty` 等
    // 既有變體 case 的先例），純粹借用「launch environment 指定畫面」通道跑功能性 UITest 與
    // 截圖對稿。
    case commentsSheetEmpty = "CommentsSheetViewEmpty"
    // LS-218：網路錯誤態（`dHSyh`）——同上，不用來做逐元件 tap target 量測。
    case commentsSheetNetworkError = "CommentsSheetViewNetworkError"
    // LS-218 merge-review R1 m3：送出留言時撞到 LS026（目標已刪）——同上，不用來做逐元件 tap
    // target 量測，純粹借用「launch environment 指定畫面」通道釘住「只呈現終態、不疊 alert」
    // 這個修正（`CommentsSheetUITests.testSendTargetGone_showsOnlyTerminalState_noAlert`）。
    case commentsSheetSendTargetGone = "CommentsSheetViewSendTargetGone"
    // LS-218 merge-review R1 m4：`familyStore.ownerUserID` 還沒就緒（同 `.diaryDetailRoleNotReady`
    // 既有先例）——同上，不用來做逐元件 tap target 量測，純粹驗證留言列／送出鈕正確變成
    // `.disabled`。
    case commentsSheetOwnerNotReady = "CommentsSheetViewOwnerNotReady"

    // LS-312：最新值卡／Segmented／新增量測／查看全部紀錄皆有代表性；04 為空狀態變體。
    case growthDetailPopulated = "ChildGrowthDetailView"
    case growthDetailEmpty = "ChildGrowthDetailViewEmpty"
    // LS-313：取代 LS-312 的兩個空殼 placeholder case——02 新增量測 sheet／03 記錄列表現在是
    // 真的表單／清單，日期欄／三個量測欄／Save／Cancel／列操作（swipe 揭露＋點列開
    // `GrowthRecordActionsSheet`）都有代表性可量。
    case growthMeasurementForm = "GrowthMeasurementFormView"
    case growthRecordsList = "GrowthRecordsListView"
    // LS-313：03c 列操作表（非手勢替代路徑）——新版面（編輯／刪除／取消三列），同
    // `ContentActionsSheet` 的既有先例（也是 `*Sheet.swift`，不在 `tap-target-registry-check.sh`
    // 自動掃描範圍內，但仍手動註冊，理由同該檔）；`GrowthRecordDeleteConfirmationSheet`
    // （03b）純粹轉呼叫既有 `DeleteConfirmationSheet`（已由 `.deleteDiaryConfirmation`／
    // `.deleteCommentConfirmation` 兩個既有 case 覆蓋同一段版面程式碼），不另掛 case。
    case growthRecordActionsSheet = "GrowthRecordActionsSheet"
    case childrenManagementPopulated = "ChildrenManagementView"  // LS-312：populated，1 個寶貝
    // LS-379：飲食圖鑑 02（示範資料 38／274，穀物根莖）——8 顆分頁＋16 格（吃過／還沒吃）皆可量。
    // 深色／02b 乳製品（一歲後標記）／02c viewer 三個變體同一支檔案，供 `FoodBookUITests` 截圖與
    // 行為斷言（同 `.settingsMemberRole` 等既有變體 case 的先例，不另外具名排除）。
    case foodBook = "FoodBookView"
    case foodBookDark = "FoodBookViewDark"
    case foodBookDairy = "FoodBookViewDairy"
    case foodBookViewer = "FoodBookViewViewer"
    // LS-365：時間軸照片卡壓印行寶貝署名——同 `.diaryCardVideoBadges` 既有先例，不是點擊目標
    // 測試，借這條通道餵 `PhotoCardBabyCaptionUITests` 量折行像素與截圖對稿；fixture（一位／
    // 兩位／三位長名／未標記／相簿卡回歸／feed）由 `LS_PHOTO_CARD_CAPTION_FIXTURE` 選，見
    // `TapTargetGateHarness+PhotoCardCaption.swift`。
    case photoCardBabyCaption = "PhotoCardBabyCaption"

    // 自測樣本（LS-95 自己的 gate 自測，不是產品畫面）：`TapTargetGateSelfTests` 專用。
    case selfTestTooSmall = "SelfTestTooSmall"
    case selfTestGood = "SelfTestGood"
    // #148 R1 I4 的漏網型：padding 掛在外層容器、不是掛在 Button 的 label／contentShape
    // 鏈上——這是 LS-95 存在的理由，這個樣本測不出來就代表整支 gate 白做。
    case selfTestPaddingOutsideButton = "SelfTestPaddingOutsideButton"
}

#endif
