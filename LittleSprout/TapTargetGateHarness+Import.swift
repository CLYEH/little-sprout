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
}
#endif
