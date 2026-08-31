#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `ChildAPIClient`——不打真網路（同 `PreviewFamilyAPIClient`
/// 的角色，見該檔）。生產路徑一律用 `SupabaseChildAPIClient`。
private final class PreviewChildAPIClient: ChildAPIClient, @unchecked Sendable {
    func listChildren(familyID: UUID) async throws -> [Child] { [] }

    func createChild(familyID: UUID, name: String, birthday: Date, avatarURL: String?) async throws -> UUID {
        UUID()
    }

    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async throws {}

    func setChildDeleted(childID: UUID, deleted: Bool) async throws {}

    func fetchMyRole(familyID: UUID) async throws -> FamilyRole? { .owner }
}

extension ChildrenStore {
    @MainActor
    static func preview() -> ChildrenStore {
        ChildrenStore(apiClient: PreviewChildAPIClient())
    }
}
#endif
