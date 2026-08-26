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

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> String {
        "K7M2FD"
    }

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
}
#endif
