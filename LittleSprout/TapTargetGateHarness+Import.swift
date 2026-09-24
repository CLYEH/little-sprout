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
        return Import05SummaryView(session: fixture.session, store: fixture.store, marker: marker, onDone: {})
    }
}
#endif
