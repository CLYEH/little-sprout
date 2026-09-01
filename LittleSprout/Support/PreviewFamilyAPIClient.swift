#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `FamilyAPIClient`——不打真網路、不需要
/// `Config/Secrets.xcconfig`（同 `PreviewAuthService` 的角色，見該檔）。生產路徑一律用
/// `SupabaseFamilyAPIClient`。
private final class PreviewFamilyAPIClient: FamilyAPIClient, @unchecked Sendable {
    func createFamily(name: String) async throws -> Family {
        Family(id: UUID(), name: name, createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    func fetchMyFamily() async throws -> Family? { nil }

    func updateFamilyName(familyID: UUID, name: String) async throws {}

    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws {}

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> InviteRecord {
        InviteRecord(id: UUID(), code: "K7M2FD", role: role, maxUses: maxUses, usedCount: 0, expiresAt: expiresAt)
    }

    func fetchLatestActiveInvite(familyID: UUID) async throws -> InviteRecord? { nil }

    func revokeInvite(id: UUID) async throws {}

    func requestJoin(code: String) async throws -> JoinRequestOutcome {
        .joined(familyID: UUID())
    }

    func approveJoin(requestID: UUID) async throws {}

    func rejectJoin(requestID: UUID) async throws {}

    func withdrawJoin(requestID: UUID) async throws {}

    func listJoinRequests() async throws -> [PendingJoinRequest] { [] }

    func myJoinRequest() async throws -> MyJoinRequest? { nil }
}

extension FamilyStore {
    @MainActor
    static func preview() -> FamilyStore {
        FamilyStore(apiClient: PreviewFamilyAPIClient())
    }

    /// LS-95 merge-review R1 M1(b)：帶著家庭狀態的 preview store。`SettingsView` 的「邀請家人」
    /// 列只在 `myFamily != nil` 才渲染（LS-107）——沒有這個工廠方法，`tap-target-check` 的
    /// harness 永遠量不到那顆列（golden run 的 `testSettingsView` 因此只點名了「登出」一顆，
    /// reviewer 實測確認）。同步呼叫 `seedMyFamilyForPreview`（見 `FamilyStore.swift`），不經過
    /// async fetch，沒有時序窗口。
    @MainActor
    static func preview(withFamily family: Family) -> FamilyStore {
        let store = FamilyStore(apiClient: PreviewFamilyAPIClient())
        store.seedMyFamilyForPreview(family)
        return store
    }
}
#endif
