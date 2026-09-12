import SwiftUI
import UIKit

/// 留言 sheet（LS-218，依 LS-177 稿 `FiBvh`／`f10d1D`／`SHbqU`／`dHSyh`／`TnxXE`／`wY7f8`／
/// `DUyg3`；Handoff Notes `EclPC` 節「留言 sheet」）——`InteractionRow.onOpenComments`（三種卡片
/// 共用）開出的清單／輸入列／空狀態／錯誤態／骨架載入／Owner 移除操作表。
///
/// 拆成四個檔案（同 `DiaryDetailView`／`DiaryDetailView+ContentActions.swift` 既有先例，避免單一
/// 檔案逼近 SwiftLint `file_length`／`type_body_length`）：本檔（版面骨架＋iPad／iPhone 分流＋
/// Head）、`+States.swift`（骨架載入／空狀態／錯誤態／LS026）、`+List.swift`（留言清單＋載入更早
/// ＋捲到底）、`+Footer.swift`（輸入列＋送出）、`+Actions.swift`（留言列操作表整條流程）。
///
/// **iPhone 全高 detent／iPad 置中卡片**：同 `LegalDocumentSheet`（LS-133／LS-191）既有理由——
/// iPad `.sheet()` 在 regular width、未強制 `presentationDetents` 時的原生行為就是置中浮動 form
/// sheet（系統行為），這裡直接沿用同一套 520／87.5 卡片配方（LS-177 Notes `j5ngNi`：「逐位元
/// 沿用 LS-133 R3 定案配方，非本票重新推導」），**不另造容器**。iPhone 用 `.presentationDetents(
/// [.large])` 明確表達「全高」（票文範圍 1）——跟同檔案家族的 `ContentActionsSheet`／
/// `DeleteConfirmationSheet`（`[.medium, .large]` 兩級）刻意不同：留言 sheet 需要空間放下清單＋
/// 輸入列，`.medium` 對這個畫面沒有意義。
///
/// **分頁**：`CommentsStore` 首載最新 `pageSize`（20，同 `docs/API.md` 預設）則＋頂端「載入更早
/// 的留言」（票文範圍 2 的取捨，見 handoff）。**留言計數同步回互動列**（票文範圍 3，merge-review
/// R1 m1 訂正）：`.onChange(of: store.knownExactCount)` 寫回
/// `timelineStore.setCommentCount(_:forKey:)`——只在 `store.hasEarlier == false`（清單已載到底、
/// `comments.count` 才等於真正總數）時才寫，不需要呼叫端手動同步；`hasEarlier == true` 時互動列
/// 既有數字保持不動，不寫入一個已知不完整卻看起來很精確的數字（見 `CommentsStore.
/// knownExactCount` 文件註解）。
///
/// 每次開啟建一份新的 `CommentsStore`（`@State` 初始值運算式只在這個 View 身分第一次出現時執行
/// 一次，見 `CommentsStore` 文件註解「每次開啟 sheet 建一份新的」）。
struct CommentsSheetView: View {
    let kind: FeedKind
    let refId: UUID
    let timelineStore: TimelineStore
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let commentAPIClient: CommentAPIClient
    let safetyAPIClient: SafetyAPIClient

    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State var store: CommentsStore
    @State var draft = ""
    @State var sendError: AppError?
    /// R2 M2（同 `LegalDocumentSheet.iPadMeasuredWidth` 既有理由）：一般全螢幕 iPad 情境下的
    /// 卡寬預設值，量到真實寬度前用它算內距，避免首幀閃爍。
    @State private var iPadMeasuredWidth: CGFloat = 520
    /// `.onChange` 觸發鍵——`+Footer.swift` 的 `sendTapped()` 送出成功後遞增，驅動
    /// `+List.swift` 的 `commentsList` 捲到底（票文範圍 3：「送出後清空並捲到底」）。用一個
    /// 遞增計數器而不是直接 watch `store.comments.count`：載入更早（在頂端插入）也會改變
    /// `count`，但那不該觸發捲到底。
    @State var draftSendSucceededTick = 0

    // MARK: - 留言列操作表（見 `+Actions.swift`）
    @State var actionsContext: CommentActionsContext?
    @State var reportFlowTarget: ContentActionTarget?
    @State var showsReportSent = false
    @State var blockConfirmContext: CommentBlockConfirmContext?
    @State var deleteConfirmTarget: CommentDeleteTarget?

    private static let iPadCardWidth: CGFloat = 520
    private static let iPadCardMaxPadding: CGFloat = 87.5
    private static let iPadCardMinContentWidth: CGFloat = 345

    init(
        kind: FeedKind, refId: UUID, familyID: UUID, timelineStore: TimelineStore, familyStore: FamilyStore,
        childrenStore: ChildrenStore, commentAPIClient: CommentAPIClient, safetyAPIClient: SafetyAPIClient
    ) {
        self.kind = kind
        self.refId = refId
        self.timelineStore = timelineStore
        self.familyStore = familyStore
        self.childrenStore = childrenStore
        self.commentAPIClient = commentAPIClient
        self.safetyAPIClient = safetyAPIClient
        _store = State(initialValue: CommentsStore(
            apiClient: commentAPIClient, familyID: familyID, targetType: kind.rawValue, targetID: refId
        ))
    }

    var isAX3: Bool { dynamicTypeSize >= .accessibility3 }
    var avatarSize: CGFloat { isAX3 ? 72 : 36 }
    private var targetKey: String { TimelineEntry.id(kind: kind, refId: refId) }
    /// `+Actions.swift`／`+Footer.swift` 需要組 `ContentActionTarget`／各確認卡的
    /// `familyID`／`familyName`——同 `TimelineStore.apiClient` 的既有存取層級理由（跨檔案
    /// extension 碰不到 `private`），這裡不能標 `private`。
    var familyID: UUID { store.familyID }
    var familyName: String { familyStore.myFamily?.name ?? "" }

    /// 目前是不是卡在「目標已刪／不屬本家庭」這個終態（票文範圍 4 LS026）——首載或送出任一個
    /// 撞到都要整張 sheet 換成這個態（`docs/API.md`：`list_comments`／`create_comment` 共用
    /// 同一個碼）。
    var targetGoneError: AppError? {
        if case .failure(let error) = store.initialLoadState, CommentsErrorPresentation.make(from: error).isTargetGone {
            return error
        }
        if case .failure(let error) = store.sendState, CommentsErrorPresentation.make(from: error).isTargetGone {
            return error
        }
        return nil
    }

    private var isPadIdiom: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isPadIdiom {
                content(horizontalPadding: iPadHorizontalPadding, showsGrabber: false)
                    .frame(maxWidth: Self.iPadCardWidth)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CommentsSheetWidthKey.self, value: proxy.size.width)
                        }
                    )
                    .onPreferenceChange(CommentsSheetWidthKey.self) { newWidth in
                        guard newWidth > 0 else { return }
                        iPadMeasuredWidth = newWidth
                    }
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(Color.lsSurface)
            } else {
                content(horizontalPadding: AppSpacing.screenPad, showsGrabber: true)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        }
        .task { await store.loadInitial() }
        .onChange(of: store.knownExactCount) { _, newValue in
            guard let newValue else { return }
            timelineStore.setCommentCount(newValue, forKey: targetKey)
        }
        .overlay(commentActionsSheetHost)
        .alert(
            "留言送出失敗",
            isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } }),
            presenting: sendError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.userFacingMessage)
        }
    }

    /// 容器寬度→內距的純函式，同 `LegalDocumentSheet.iPadCardAdaptivePadding` 既有理由（容器
    /// ≥520 內距封頂 87.5；容器變窄時內距降到 24 下限，內容欄跟著收縮但保證最小呼吸間距）。
    static func iPadCardAdaptivePadding(containerWidth: CGFloat) -> CGFloat {
        let computed = (containerWidth - iPadCardMinContentWidth) / 2
        return min(iPadCardMaxPadding, max(AppSpacing.screenPad, computed))
    }

    private var iPadHorizontalPadding: CGFloat { Self.iPadCardAdaptivePadding(containerWidth: iPadMeasuredWidth) }

    // MARK: - 版面（iPhone 全高 sheet／iPad 置中卡片共用同一份骨架，差異只在寬度與 Grabber）

    private func content(horizontalPadding: CGFloat, showsGrabber: Bool) -> some View {
        VStack(spacing: 0) {
            if showsGrabber { grabber }
            head.padding(.horizontal, horizontalPadding).padding(.top, AppSpacing.tight)
            Rectangle().fill(Color.lsBorder).frame(height: 1)
                .padding(.horizontal, horizontalPadding).padding(.top, AppSpacing.block)
            if let targetGoneError {
                targetGoneState(for: targetGoneError, horizontalPadding: horizontalPadding)
            } else {
                mainBody(horizontalPadding: horizontalPadding, isPadIdiom: isPadIdiom)
            }
        }
        .background(Color.lsSurface)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text("留言")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            // `dHSyh` 稿面用一個全形空白佔位保留高度，不用「0 則留言」——載入完成前／失敗時
            // 顯示筆數沒有意義，見該板文件註解。merge-review R1 m1：`hasEarlier == true` 時
            // `store.commentCount` 只是「至少這麼多」，不是總數——這裡是 sheet 內部，使用者
            // 往下就能看到清單與「載入更早的留言」鈕，用「+」誠實標示不確定並不會誤導（同
            // `store.knownExactCount` 只在確定總數時才寫回互動列的裁量不同：互動列在 sheet
            // 外，看不到清單佐證，不能用同一套「+」標示）。
            Text(headCommentCountText)
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headCommentCountText: String {
        Self.headCommentCountText(
            initialLoadState: store.initialLoadState, commentCount: store.commentCount, hasEarlier: store.hasEarlier
        )
    }

    /// 抽成靜態純函式方便單元測試（同 `CommentsErrorPresentation.make(from:)` 既有慣例：不依賴
    /// View 就能測分岔）——merge-review R1 m1。
    static func headCommentCountText(
        initialLoadState: CommentsOperationState, commentCount: Int, hasEarlier: Bool
    ) -> String {
        guard initialLoadState == .success else { return "\u{3000}" }
        return hasEarlier ? "\(commentCount)+ 則留言" : "\(commentCount) 則留言"
    }
}

/// `.background(GeometryReader)` 量寬——同 `LegalDocumentSheetWidthKey` 既有理由（`defaultValue
/// = 0`＋`reduce` 用 `max`，避免沒設 preference 的兄弟節點用 `defaultValue` 蓋掉真正量到的值）。
private struct CommentsSheetWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
