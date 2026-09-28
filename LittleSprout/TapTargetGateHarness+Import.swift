#if DEBUG
import SwiftUI

/// LS-303：相機膠卷批次匯入三個 harness host——拆出獨立檔案，同 `TapTargetGateHarness
/// +Albums.swift`／`+UploadQueue.swift` 既有拆檔理由（`TapTargetGateHarness.swift` 本體
/// `hostView(for:)` switch 已經很長，同檔繼續塞會超過 `file_length`）。
extension TapTargetGateHarness {
    /// 固定 fixture（同 `ImportOrganizeView` 的 `#Preview` fixture）——不需要真的 `PHAsset`，
    /// 見 `ImportOrganizeView.init(childrenStore:albumsStore:uploadCoordinator:plan:accessState:
    /// assetLimit:)` 文件註解。
    @MainActor
    @ViewBuilder
    static var importOrganizeDefaultHost: some View {
        ImportOrganizeView(
            childrenStore: .preview(), albumsStore: .preview(), uploadCoordinator: NoOpImportUploadCoordinator(),
            plan: ImportPlan.previewFixture, accessState: .authorized
        )
    }

    @MainActor
    @ViewBuilder
    static var importOrganizeLimitedHost: some View {
        ImportOrganizeView(
            childrenStore: .preview(), albumsStore: .preview(), uploadCoordinator: NoOpImportUploadCoordinator(),
            plan: ImportPlan.previewFixture, accessState: .limited
        )
    }

    @MainActor
    @ViewBuilder
    static var importPermissionDeniedHost: some View {
        ImportPermissionDeniedView()
    }

    // LS-304：04／05——`ImportPreviewFixture.makeBatch()`（`Import04ProgressView.swift`
    // `#if DEBUG`）建一份 session／store 對得上的固定樣本，同 `#Preview` 共用。
    @MainActor
    @ViewBuilder
    static var importProgressDefaultHost: some View {
        let fixture = ImportPreviewFixture.makeBatch()
        Import04ProgressView(
            session: fixture.session, store: fixture.store,
            onLeaveInBackground: {}, onAllItemsFinished: {}, onCancelledImport: {}
        )
    }

    @MainActor
    @ViewBuilder
    static var importProgressCancelConfirmHost: some View {
        Import04bCancelConfirmView(uploadedCount: 34, remainingCount: 94, onKeepGoing: {}, onConfirmCancel: {})
    }

    @MainActor
    @ViewBuilder
    static var importSummaryWithFailuresHost: some View {
        let fixture = ImportPreviewFixture.makeBatch(completed: 5, uploading: 0, waiting: 0, failed: [.network, .quota])
        let marker = AlbumsStore.preview().mediaChildrenMarker
        Import05SummaryView(session: fixture.session, store: fixture.store, marker: marker, onDone: {})
    }

    /// LS-319：05 完成摘要頁疊「寶貝標記未完成」——`seedFailedMarkingForPreview` 直接灌狀態
    /// （不經過真正的 RPC，見該方法文件註解），`entryIDs` 取這份 fixture 真正的
    /// `session.entryIDSet` 子集，讓「其中 N 張的寶貝沒有指定成功」與「補上寶貝（N）」（LS-373）對得上。
    @MainActor
    @ViewBuilder
    static var importSummaryWithMarkingFailureHost: some View {
        let fixture = ImportPreviewFixture.makeBatch(completed: 5, uploading: 0, waiting: 0, failed: [.network, .quota])
        let marker = AlbumsStore.preview().mediaChildrenMarker
        let markedEntryIDs = Array(fixture.session.entryIDs.prefix(2))
        marker.seedFailedMarkingForPreview(entryIDs: markedEntryIDs, mediaIDs: markedEntryIDs)
        // LS-373：同批再疊「沒有加入」列（D2），一個 host 就涵蓋統計卡三類頂層列＋寶貝子列。
        fixture.session.markGroupResolved(droppedCount: 3)
        return Import05SummaryView(session: fixture.session, store: fixture.store, marker: marker, onDone: {})
    }

    /// LS-391：`.importBatchFlowEntry`／`.importBatchFlowEntryDark` 兩 case 共用一行分派（`hostView(for:)`
    /// 所在的 enum 已貼齊 SwiftLint `type_body_length` 上限）。
    @MainActor
    @ViewBuilder
    static func importBatchFlowEntryHost(for screen: TapTargetGateScreenName) -> some View {
        ImportBatchFlowEntryHost().preferredColorScheme(screen == .importBatchFlowEntryDark ? .dark : .light)
    }
}

/// LS-391：`.importBatchFlowEntry(Dark)` host——掛**正式的** `.importBatchFlow` modifier（真的
/// 相片庫授權＋PHPicker＋`.fullScreenCover`），讓 `ImportFlowTopBarSafeAreaUITests` 走到跟
/// 產品一模一樣的呈現時序：頂列畫進狀態列只在「picker dismiss 轉場途中 present cover」時
/// 出現，把畫面直接當根 view（上面各 host）或單純包一層 `.fullScreenCover` 都重現不出來
/// （LS-391 r1 截圖）。入口鈕貼齊 safe area 頂端，UITest 拿它的 `minY` 當 safe area top 參照。
struct ImportBatchFlowEntryHost: View {
    @State private var isActive = false
    @State private var childrenStore = ChildrenStore.preview()
    @State private var albumsStore = AlbumsStore.preview()

    var body: some View {
        VStack(spacing: 0) {
            // frame 做在 label 內部，按鈕的 accessibility frame 才會從 safe area 頂端算起（外掛
            // `.frame` 只撐版面、frame 仍是文字本身，見 `ImportOrganizeView.navRow` 註解）。
            Button {
                isActive = true
            } label: {
                Text("開始批次匯入").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }
            Spacer(minLength: 0)
        }
        .appBackground()
        .importBatchFlow(
            isActive: $isActive, childrenStore: childrenStore, albumsStore: albumsStore, entrySource: .timeline,
            uploadCoordinator: HarnessCompletedImportCoordinator(albumsStore: albumsStore)
        )
    }
}

/// LS-391：主鈕按下後不真的上傳——每張直接以「已完成」種進 app 層級共用佇列，讓
/// `ImportBatchFlowContainer` 走 04 → 05。群「已解決」延後 3 秒才標，04 才會在畫面上停得夠久
/// 讓 UITest 驗它的頂列（`Import04ProgressView.checkAllFinished` 要 `isFullyEnqueued`）。
private struct HarnessCompletedImportCoordinator: ImportUploadCoordinator {
    let albumsStore: AlbumsStore

    @MainActor
    func startImport(plan: ImportPlan) -> ImportBatchSession {
        let store = albumsStore.sharedUploadQueueStore(
            familyID: UUID(), mediaUploadService: PreviewMediaUploadService()
        )
        let session = ImportBatchSession(expectedAssetCount: plan.pendingAssetCount, nonSkippedGroupCount: 1)
        let seeds = (0..<plan.pendingAssetCount).map { _ in
            let upload = PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
            session.append(upload.id)
            return UploadQueueStore.PreviewSeed(upload, enqueuedAt: Date(), state: .completed)
        }
        store.seedForPreview(seeds)
        Task {
            try? await Task.sleep(for: .seconds(3))
            session.markGroupResolved()
        }
        return session
    }
}
#endif
