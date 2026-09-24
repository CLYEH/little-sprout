#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `ChildAPIClient`——不打真網路（同 `PreviewFamilyAPIClient`
/// 的角色，見該檔）。生產路徑一律用 `SupabaseChildAPIClient`。
private final class PreviewChildAPIClient: ChildAPIClient, @unchecked Sendable {
    /// LS-370：`refresh(familyID:)` 會用這份清單覆蓋 `children`——harness 若 seed 了家庭，只靠
    /// `seedForPreview(children:)` 種的寶貝會在 `.task` 觸發 refresh 時被 `[]` 蓋掉。
    private let children: [Child]

    init(children: [Child] = []) {
        self.children = children
    }

    func listChildren(familyID: UUID) async throws -> [Child] { children }

    func createChild(familyID: UUID, name: String, birthday: Date, avatarURL: String?) async throws -> UUID {
        UUID()
    }

    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async throws {}

    func setChildDeleted(childID: UUID, deleted: Bool) async throws {}

    func fetchMyRole(familyID: UUID) async throws -> FamilyRole? { .owner }

    func signedAvatarURLs(forPaths paths: [String]) async throws -> [String: URL] { [:] }
}

/// 只給 SwiftUI `#Preview` 用的假 `ChildAvatarUploadService`——不打真網路（同
/// `PreviewChildAPIClient` 的角色）。回傳一個固定的假路徑，不代表真的上傳過任何東西。
private final class PreviewChildAvatarUploadService: ChildAvatarUploadService, @unchecked Sendable {
    func uploadAvatar(familyID: UUID, childID: UUID, imageData: Data) async throws -> String {
        "\(familyID.uuidString.lowercased())/avatars/\(childID.uuidString.lowercased()).jpg"
    }
}

extension ChildrenStore {
    @MainActor
    static func preview(children: [Child] = []) -> ChildrenStore {
        ChildrenStore(
            apiClient: PreviewChildAPIClient(children: children), avatarUploadService: PreviewChildAvatarUploadService()
        )
    }
}
#endif
