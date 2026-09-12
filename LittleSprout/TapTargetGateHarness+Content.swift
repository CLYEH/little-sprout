#if DEBUG
import SwiftUI

/// LS-190：`EULAConsentView`／`DeleteConfirmationSheet` 兩個變體的 harness host，從
/// `TapTargetGateHarness.swift` 拆出獨立檔案——同 `TapTargetGateHarness+Legal.swift`（LS-191）
/// 的既有先例：那支檔案疊上新 case 後會超過 SwiftLint `file_length` 上限。
extension TapTargetGateHarness {
    /// `EULAConsentView` 不需要真的打網路即有代表性——`EULAStore.preview(shouldPresent: true)`
    /// 同步灌好狀態（同 `FamilyStore.preview(withFamily:)` 的既有作法）。
    @MainActor
    static var eulaConsentHost: some View {
        EULAConsentView(eulaStore: .preview(shouldPresent: true), onDisagree: {})
    }

    /// `DiaryDeleteConfirmationSheet` 沒有免登入即可到達的產品入口（`DiaryDetailView` 需要
    /// `TimelineStore` 帶一篇日記與附照資料才有代表性，仍在 `tap-target-exemptions.txt`）——同
    /// `uploadQueueSheetHost`／`legalDocumentSheetHost` 的既有作法，用一個常駐顯示的 sheet
    /// 頂出來。**不用 `.constant(true)`**（跟 `+Legal.swift`／`+UploadQueue.swift` 既有 host
    /// 不同的一點）：`DeleteConfirmationSheet` 自己的「確認」／「取消」都會呼叫
    /// `@Environment(\.dismiss)`，這支 action 是透過把 `isPresented` 綁定寫回 `false` 生效——
    /// `.constant` 綁定的 setter 是 no-op，UITest 斷言「確認後 sheet 真的關閉」在那種 host 上
    /// 測不出來（本檔其餘既有 host 也沒有測過這件事）。這裡改用真的 `@State`（見下方
    /// `DismissableSheetHost`），讓「確認／取消都會讓 sheet 真的消失」這件事可以被 UITest
    /// 覆蓋到。
    @MainActor
    static var deleteDiaryConfirmationHost: some View {
        DismissableSheetHost {
            DiaryDeleteConfirmationSheet(
                diaryID: UUID(), diaryBody: "今天在溜滑梯上玩得好開心。",
                diaryAPIClient: PreviewDiaryAPIClient(), onDeleted: {}
            )
        }
    }

    /// `CommentDeleteConfirmationSheet` 目前沒有任何真實產品入口（留言 UI 本體／內容操作表都
    /// 尚未實作，見該檔文件註解）——這是唯一能觸達它的入口，同上一個 host 的理由。
    @MainActor
    static var deleteCommentConfirmationHost: some View {
        DismissableSheetHost {
            CommentDeleteConfirmationSheet(
                commentID: UUID(), commentAPIClient: PreviewCommentAPIClient(), onDeleted: {}
            )
        }
    }

    /// LS-190 票文驗收「UITests：首次登入 → EULA 出現 → 同意 → 進時間軸」——直接建構
    /// `AuthenticatedGate`（見該型別文件註解，LS-190 起非 private），是唯一真的走過
    /// 「`eulaStore.shouldPresent` 從 true 翻成 false 之後，畫面樹自動換到主畫面」這段反應式
    /// 邏輯的入口；`.eulaConsent` 那個 case 只掛了 `EULAConsentView` 本體，接不到這段轉換。
    ///
    /// `authStore` 用 `seedSessionForPreview` 灌一個假 session（`AuthStore.preview()` 底層的
    /// `PreviewAuthService.currentSession` 預設 nil，一般建構不出「已登入」狀態）；
    /// `familyStore` 用 `seedMyFamilyForPreview(_:ownerUserID:)` 帶 `ownerUserID` 版本（見該檔
    /// 文件註解）讓 `syncOwner(to:)` 短路，不會被 `PreviewFamilyAPIClient` 固定回傳 `nil` 的
    /// `fetchMyFamily()` 洗掉剛種好的家庭。**刻意不 seed `timelineStore`**（同
    /// `sectionTabViewWithDiaryHost` 文件註解點名的既有陷阱：`TimelineView` 自己的
    /// `.task(id:)` 會在 `myFamily` 非 nil 時真的打 `PreviewTimelineAPIClient`，蓋掉任何預先
    /// seed 的假資料）——UITest 斷言的是空狀態下必定渲染的時間軸 Header「時間軸」文字（同
    /// `.sectionTabView` 既有 sentinel），不依賴任何 seed 資料，剛好避開這個陷阱。
    @MainActor
    static var eulaConsentToTimelineHost: some View {
        let authStore = AuthStore.preview()
        let userID = UUID()
        authStore.seedSessionForPreview(
            AuthSession(userID: userID, email: "grandma@example.com", expiresAt: .distantFuture)
        )
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "測試家庭", createdBy: userID, createdAt: Date(), requireApproval: true),
            ownerUserID: userID
        )
        return AuthenticatedGate(
            authStore: authStore, familyStore: familyStore, childrenStore: .preview(), timelineStore: .preview(),
            albumsStore: .preview(), eulaStore: .preview(shouldPresent: true, judgedUserID: userID),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
            accountAPIClient: PreviewAccountAPIClient(), resumer: .preview(),
            safetyAPIClient: PreviewSafetyAPIClient(), commentAPIClient: PreviewCommentAPIClient(),
            // LS-217：`.authorized`（非 `.notDetermined`）——避免這支流程測試意外撞上
            // `AuthenticatedRootView` 新增的「登入後首次進時間軸」推播前置頁 `fullScreenCover`
            // （`.preview()` 預設 `.notDetermined` 會讓 `showsPreprompt` 判定為 true，蓋住這支
            // 測試要斷言的時間軸 Header，見 `PushPrepromptPolicy`）。
            pushNotificationStore: .preview(authorizationStatus: .authorized),
            pendingInviteCode: .constant(nil)
        )
        .environment(\.horizontalSizeClass, .compact)
    }
}

/// 見 `TapTargetGateHarness.deleteDiaryConfirmationHost` 文件註解——用真的 `@State` 而非
/// `.constant(true)`，讓 sheet 的「確認」／「取消」按下 `dismiss()` 之後真的消失（不會像
/// `.constant` 綁定那樣被無視），UITest 才能斷言得到「sheet 已關閉」這件事。
///
/// LS-189：不標 `private`——`TapTargetGateHarness+Safety.swift`（跨檔案 extension）需要重用
/// 同一個 host，不重造一份幾乎一樣的型別。
struct DismissableSheetHost<SheetContent: View>: View {
    @State private var isPresented = true
    let sheetContent: () -> SheetContent

    init(@ViewBuilder sheetContent: @escaping () -> SheetContent) {
        self.sheetContent = sheetContent
    }

    var body: some View {
        Color.lsBackground
            .sheet(isPresented: $isPresented, content: sheetContent)
    }
}
#endif
