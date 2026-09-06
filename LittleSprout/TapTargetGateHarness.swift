#if DEBUG
import AVFoundation
import SwiftUI
import UIKit

/// LS-95：≥44pt 點擊目標機械 gate 的畫面掛載點。
///
/// XCUITest 啟動 app 時沒辦法「憑空」跳過登入／建立家庭流程直接開到某個 Feature 畫面——
/// `tap-target-check.sh`（透過 `TapTargetGateTests`）用 `LS_TAP_TARGET_GATE_SCREEN` 這個
/// launch environment 變數（值見 `TapTargetGateScreenName`）告訴 app「這次啟動請直接顯示這個
/// 畫面」，用既有 `#Preview` 已經在用的同一組 `.preview()` mock store 建構，不打真網路、不需要
/// `Config/Secrets.xcconfig`。
///
/// 只有 `TapTargetGateTests`／`TapTargetGateSelfTests` 會設這個環境變數，一般使用者啟動 app
/// 永遠讀不到、走 `LittleSproutApp.body` 原本的 `RootView` 路徑。整支 `#if DEBUG` 圍住——依賴
/// 的 `.preview()` 系列本身就只在 DEBUG 存在（見 `PreviewAuthService.swift` 等），Release
/// build 不會編到這支檔案，也不可能被誤觸發。
///
/// 新增受測畫面：`TapTargetGateScreenName` 加一個 case，這裡的 `hostView` 補對應分支。
enum TapTargetGateHarness {
    static var activeScreen: TapTargetGateScreenName? {
        ProcessInfo.processInfo.environment["LS_TAP_TARGET_GATE_SCREEN"]
            .flatMap(TapTargetGateScreenName.init(rawValue:))
    }

    // LS-169：這支函式是純粹的「畫面名稱 → View」1:1 dispatch（每個 case 只轉呼叫一個
    // computed var，本身沒有分支邏輯），複雜度隨已註冊的畫面數量線性成長是這個形狀必然的
    // 副作用，不是真正難懂／難測的巢狀邏輯——`ChildFilterLayout`（該檔文件註解）用查表
    // 換掉 switch 是因為那裡回傳單一 enum 值；這裡回傳 `some View`，每個 case 是不同的
    // 具體型別，查表在 Swift 型別系統下不成立，只能用 switch。
    @MainActor
    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func hostView(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .otpVerification:
            otpVerificationHost
        case .settings: settingsHost
        case .settingsMemberRole: settingsMemberRoleHost
        case .settingsRegular: settingsRegularHost
        case .diaryEditor:
            diaryEditorHost
        case .createChild:
            createChildHost
        case .timelineDefaultState:
            timelineDefaultStateHost
        case .albumsDefaultState:
            albumsDefaultStateHost
        case .albumsPopulatedState:
            albumsPopulatedStateHost
        case .createAlbum:
            createAlbumHost
        case .sectionTabView:
            sectionTabViewHost
        case .sectionTabViewWithDiary:
            sectionTabViewWithDiaryHost
        case .diaryCardVideoBadges:
            diaryCardVideoBadgesHost
        case .uploadQueueSheet:
            uploadQueueSheetHost
        case .uploadQueueSheetNormal:
            uploadQueueSheetNormalHost
        case .passwordSignIn: passwordSignInHost
        case .welcome: welcomeHost
        case .profileEdit: profileEditHost
        case .familyMembers: familyMembersHost
        case .deleteAccountGeneralMember: deleteAccountGeneralMemberHost
        case .deleteAccountMustTransfer: deleteAccountMustTransferHost
        case .deleteAccountSoleMember: deleteAccountSoleMemberHost
        case .deleteAccountFinalConfirm: deleteAccountFinalConfirmHost
        case .deleteAccountCompleted: deleteAccountCompletedHost
        case .deleteAccountFailed: deleteAccountFailedHost
        case .deleteAccountInProgress: deleteAccountInProgressHost
        case .contentActionsSheet, .reportReasonSheet, .reportReasonSheetTargetGone, .blockConfirmSheet,
             .ownerRemoveContentConfirmSheet, .blockList, .reportInbox, .reportInboxEmpty,
             .reportInboxResolveError, .diaryDetail, .diaryDetailOwnContent, .diaryDetailRoleNotReady:
            // LS-189：十二個新 case 的分派抽到 `safetyHostView(for:)`（見
            // `TapTargetGateHarness+Safety.swift`）——直接列在這裡會讓這支函式再度超過
            // SwiftLint `function_body_length` 上限（同其餘 `*Host` computed var 抽檔的既有
            // 理由，這裡多加一層 `default`-style 分派而不是抽 computed var，因為要分派的是
            // switch case 本身，不是單一 host 的建構邏輯）。
            safetyHostView(for: screen)
        case .legalDocumentSheet: legalDocumentSheetHost
        case .legalDocumentNarrowContainer: legalDocumentNarrowContainerHost
        case .eulaConsent: eulaConsentHost
        case .deleteDiaryConfirmation: deleteDiaryConfirmationHost
        case .deleteCommentConfirmation: deleteCommentConfirmationHost
        case .eulaConsentToTimelineFlow: eulaConsentToTimelineHost
        case .selfTestTooSmall:
            selfTestTooSmallHost
        case .selfTestGood:
            selfTestGoodHost
        case .selfTestPaddingOutsideButton:
            selfTestPaddingOutsideButtonHost
        }
    }

    // merge LS-164：`hostView(for:)` 的 switch 本體疊上帳密登入兩個新 case 後再度超過
    // SwiftLint `function_body_length` 上限，把三個既有的自測樣本 case 抽出來還給界限內，
    // 行為完全不變（同其餘 `*Host` computed var 的既有作法）。
    private static var selfTestTooSmallHost: some View {
        // `.frame()` 直接接在 `Button(_:action:)` 後面不可靠：純文字、預設樣式的按鈕，
        // accessibility／hit-test frame 實測仍貼著文字本身的天然大小，不會被外層 `.frame`
        // 撐大或縮小（LS-95 開發期間實測撞到——這正是本票要抓的那種「視覺／版面大小」跟
        // 「真正 hit-test 大小」對不上的落差）。改用 `.contentShape(Rectangle())` 明確把
        // hit-test 形狀鎖定成 `.frame` 給的矩形，樣本大小才會是可控、決定性的數字。
        Button(action: noop) {
            Text("小按鈕")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
    }

    private static var selfTestGoodHost: some View {
        Button(action: noop) {
            Text("好按鈕")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private static var selfTestPaddingOutsideButtonHost: some View {
        // 刻意重現 LS-17 QA1 的原始寫法（PR #148 R1 F1 修正前）：padding 掛在 Button 外層
        // 的 VStack，不是掛在 Button 的 label closure 裡再接 `.contentShape(Rectangle())`
        // ——視覺上按鈕四周看起來有一大圈空白，但那圈空白不參與 hit test，實際可點區域仍
        // 只有內容本身的大小（20×20，用同一招 `.contentShape` 鎖定成決定性數字）。
        VStack {
            Button(action: noop) {
                Text("小按鈕")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .padding(20)
    }

    /// merge LS-167：`hostView(for:)` 的 switch 本體因為疊了多張票的新 case（`.uploadQueueSheet`
    /// 系列、LS-165 相簿系列）超過 SwiftLint `function_body_length` 上限，把這個既有 case
    /// 的內容抽出來還給界限內，行為完全不變。
    @MainActor
    @ViewBuilder
    private static var otpVerificationHost: some View {
        NavigationStack {
            // cooldownSeconds: 0：一開畫面 `canResend` 就是 true，重寄 Button 立刻顯示
            // （見 `OTPVerificationView.init` 文件註解），不必真的等 60 秒冷卻。
            OTPVerificationView(email: "grandma@example.com", authStore: .preview(), cooldownSeconds: 0) {}
        }
    }

    /// merge-review R1 M5：初始態不需要任何 seeding——`PreviewDiaryAPIClient`／
    /// `PreviewMediaUploadService`（`Support/PreviewDiaryAPIClient.swift`，同樣是
    /// `#Preview` 在用的假 client）＋既有 `ChildrenStore.preview()`，跟 `DiaryEditorView`
    /// 自己的 `#Preview("空白")` 是同一組建構。拆成獨立 computed var（不是留在 `hostView`
    /// 的 switch 本體裡）：merge LS-125／LS-126 後兩個新 case 加起來讓 `hostView` 超過
    /// SwiftLint `function_body_length` 上限，各自的建構邏輯本來就跟其他 case 無關，抽出
    /// 去不影響行為，只是把長度還給界限內。
    @MainActor
    @ViewBuilder
    private static var diaryEditorHost: some View {
        NavigationStack {
            DiaryEditorView(
                familyID: UUID(), diaryAPIClient: PreviewDiaryAPIClient(),
                mediaUploadService: PreviewMediaUploadService(), childrenStore: .preview()
            )
        }
    }

    /// LS-169：初始態（未選圖）就有代表性，`.preview()` 免登入即可建構——同 `diaryEditorHost`
    /// 的理由，拆成獨立 computed var 只是為了不讓 `hostView` 的 switch 本體超過
    /// SwiftLint `function_body_length`／`cyclomatic_complexity` 上限。
    @MainActor
    @ViewBuilder
    private static var createChildHost: some View {
        NavigationStack {
            CreateChildView(childrenStore: .preview())
        }
    }

    /// LS-164：初始態（空欄位）不需要任何 seed 資料，同 `createChildHost` 的既有理由。
    @MainActor
    @ViewBuilder
    private static var passwordSignInHost: some View {
        NavigationStack {
            PasswordSignInView(authStore: .preview()) {}
        }
    }

    /// LS-164：見 `TapTargetGateScreenName.welcome` 文件註解——這個 host 純粹借用「launch
    /// environment 指定畫面」通道給 `PasswordSignInUITests` 用，不掛進 `TapTargetGateTests`。
    @MainActor
    private static var welcomeHost: WelcomeView {
        WelcomeView(authStore: .preview())
    }

    /// `.preview()` 三個 store 皆空狀態（無家庭／無寶貝／無 feed），`ChildFilterBar`
    /// 因 `childrenStore.activeChildren.isEmpty` 不會渲染，畫面上唯一的可點元件就是
    /// Header 的「新增回憶」建立鈕——不需要任何 seed 資料就有代表性。merge LS-125：
    /// `TimelineView` 現在直接持有 `diaryAPIClient`／`mediaUploadService`（同
    /// `diaryEditorHost` 用的假 client），才能建構。理由同上，拆成獨立 computed var。
    @MainActor
    @ViewBuilder
    private static var timelineDefaultStateHost: some View {
        NavigationStack {
            TimelineView(
                familyStore: .preview(), childrenStore: .preview(), timelineStore: .preview(),
                diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
                safetyAPIClient: PreviewSafetyAPIClient()
            )
        }
    }

    /// LS-136：`SectionTabView`（compact，四分頁）＋`SectionTabBar`。同 `.settings` 案例的家庭
    /// seeding 理由——`AuthenticatedRootView` 走 `familyStore.myFamily != nil` 分支才會顯示
    /// tab bar，不然會落在 `ForkView` 三岔路。`.environment(\.horizontalSizeClass, .compact)`
    /// 同 `RootView.swift` `#Preview("Compact")` 既有寫法，強制走 `SectionTabView` 而非
    /// `SectionSplitView`（不依賴模擬器實際 size class）。
    @MainActor
    @ViewBuilder
    private static var sectionTabViewHost: some View {
        AuthenticatedRootView(
            authStore: .preview(),
            familyStore: .preview(withFamily: Family(
                id: UUID(), name: "測試家庭", createdBy: UUID(), createdAt: Date(), requireApproval: true
            )),
            childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
            accountAPIClient: PreviewAccountAPIClient(), resumer: .preview(),
            safetyAPIClient: PreviewSafetyAPIClient()
        )
        .environment(\.horizontalSizeClass, .compact)
    }

    /// merge-review R1 M1 回歸測試用：同 `sectionTabViewHost`，但 `timelineStore` 額外
    /// `seedForPreview` 一筆日記——時間軸空狀態沒有任何可點的卡片，無法真的 push 進
    /// `DiaryDetailView`（`SectionTabBarPushRegressionTests` 需要）。body 用可獨立辨識的
    /// 字串（不會跟畫面上其他文字撞名），UI test 直接點它進入詳情頁。
    /// `@ViewBuilder` body 不能塞裸的 void 陳述式（`timelineStore.seedForPreview(...)` 這種呼叫
    /// 會被 `buildExpression` 硬吃成一個 View 表達式而編譯失敗）——seeding 副作用抽到這支普通
    /// 函式裡，`@ViewBuilder` var 那邊只留一個單純的 `let` 賦值。
    @MainActor
    private static func seededTimelineStore() -> TimelineStore {
        let store = TimelineStore.preview()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: UUID(), occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "LS-136 R2 回歸測試日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0
                ))
            )
        ])
        return store
    }

    /// 刻意**不** seed 家庭（跟 `sectionTabViewHost` 不同）：`TimelineView` 掛在畫面上就會跑
    /// `.task(id: familyStore.myFamily?.id)`／`.task(id: TimelineRefreshKey(...))`，兩支都會
    /// 呼叫 `timelineStore.refresh(...)`——若 `myFamily` 非 nil，會真的打
    /// `PreviewTimelineAPIClient.fetchTimelinePointers`（固定回傳 `[]`）蓋掉上面 seed 的那一筆，
    /// 畫面打回「還沒有回憶」空狀態（實測撞到）。`myFamily == nil` 時兩支 `.task` 的
    /// `guard let familyID = familyStore.myFamily?.id else { return }` 直接短路，seed 的資料
    /// 才留得住。這個變體本來就只為了讓卡片可點、push 進 `DiaryDetailView`，不需要家庭狀態。
    @MainActor
    @ViewBuilder
    private static var sectionTabViewWithDiaryHost: some View {
        let timelineStore = seededTimelineStore()
        AuthenticatedRootView(
            authStore: .preview(), familyStore: .preview(),
            childrenStore: .preview(), timelineStore: timelineStore, albumsStore: .preview(),
            eulaStore: .preview(shouldPresent: false),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
            accountAPIClient: PreviewAccountAPIClient(), resumer: .preview(),
            safetyAPIClient: PreviewSafetyAPIClient()
        )
        .environment(\.horizontalSizeClass, .compact)
    }

    private static func noop() {}
}
#endif
