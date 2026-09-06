#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `EULAAPIClient`——不打真網路、不需要
/// `Config/Secrets.xcconfig`（同 `PreviewFamilyAPIClient` 的角色，見該檔）。生產路徑一律用
/// `SupabaseEULAAPIClient`。
private final class PreviewEULAAPIClient: EULAAPIClient, @unchecked Sendable {
    func fetchCurrentVersion() async throws -> String { "2026-09-05-draft" }
    func fetchAcceptedVersion(userID: UUID) async throws -> String? { nil }
    func acceptEULA(version: String) async throws {}
}

extension EULAStore {
    /// `TapTargetGateHarness.eulaConsentHost` 用：同步把 `shouldPresent`／`currentVersion`
    /// 灌好，不經過 async `checkStatus`，跟 `FamilyStore.seedMyFamilyForPreview` 同樣的理由
    /// ——harness 需要免登入、無時序窗口就能直接渲染出畫面。`judgedUserID`（LS-190 R2）：
    /// `eulaConsentToTimelineHost` 需要傳跟 `authStore.seedSessionForPreview` 同一個
    /// `userID`，`isKnown(for:)` 才會判定為已知，見 `EULAStore.seedForPreview` 文件註解。
    @MainActor
    static func preview(shouldPresent: Bool, judgedUserID: UUID? = nil) -> EULAStore {
        let store = EULAStore(apiClient: PreviewEULAAPIClient())
        store.seedForPreview(
            shouldPresent: shouldPresent, currentVersion: "2026-09-05-draft", judgedUserID: judgedUserID
        )
        return store
    }
}
#endif
