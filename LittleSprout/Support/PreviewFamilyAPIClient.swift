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

    /// LS-188：預設回傳「還有空間」的樣本值（2.1／5 GB，跟 09 板核可稿同一組示意數字）——
    /// 需要「已滿」樣本（09b／`TapTargetGateHarness`）的呼叫端改呼叫
    /// `FamilyStore.seedQuotaForPreview(_:)`（同步覆寫，同 `seedMyFamilyForPreview` 的既有作法）。
    func fetchQuota(familyID: UUID) async throws -> FamilyQuota {
        FamilyQuota(usedBytes: 2_254_857_830, quotaBytes: 5_368_709_120)
    }

    func requestJoin(code: String) async throws -> JoinRequestOutcome {
        .joined(familyID: UUID())
    }

    func approveJoin(requestID: UUID) async throws {}

    func rejectJoin(requestID: UUID) async throws {}

    func withdrawJoin(requestID: UUID) async throws {}

    func listJoinRequests() async throws -> [PendingJoinRequest] { [] }

    func myJoinRequest() async throws -> MyJoinRequest? { nil }

    /// LS-192：預設回傳兩位樣本成員（一位 owner——即「自己」，一位 member）——`FamilyMembersView`
    /// 的 `#Preview` 需要看得到列表本身，需要「唯一 owner」樣本的呼叫端改用 `FamilyStore
    /// .seedMembersForPreview(_:)`（同步覆寫，同 `seedMyFamilyForPreview` 的既有作法）。
    func listMembers(familyID: UUID) async throws -> [FamilyMember] { [] }

    func removeMember(familyID: UUID, userID: UUID) async throws {}

    func transferOwnership(familyID: UUID, toUserID: UUID) async throws -> TransferOwnershipResult {
        TransferOwnershipResult(fromUserID: UUID(), fromRole: .member, toUserID: toUserID, toRole: .owner)
    }

    func fetchMyProfile() async throws -> Profile {
        Profile(id: UUID(), displayName: "陳美玲", avatarURL: nil)
    }

    func updateDisplayName(_ name: String) async throws -> Profile {
        Profile(id: UUID(), displayName: name, avatarURL: nil)
    }

    func updateAvatarPath(_ path: String) async throws -> Profile {
        Profile(id: UUID(), displayName: "陳美玲", avatarURL: path)
    }

    func signedAvatarURLs(forPaths paths: [String]) async throws -> [String: URL] { [:] }
}

/// LS-192：`FamilyStore` 的 `avatarUploadService` 需要一支假實作——同
/// `PreviewChildAPIClient.swift` 的 `PreviewChildAvatarUploadService`（那支是 `private`，
/// 跨檔案存取不到，這裡另外重複一份最小實作，同 `signedAvatarURLs` 那類小重複的既有慣例）。
private final class PreviewProfileAvatarUploadService: ChildAvatarUploadService, @unchecked Sendable {
    func uploadAvatar(familyID: UUID, childID: UUID, imageData: Data) async throws -> String {
        "\(familyID.uuidString.lowercased())/avatars/\(childID.uuidString.lowercased()).jpg"
    }
}

extension FamilyStore {
    @MainActor
    static func preview() -> FamilyStore {
        FamilyStore(apiClient: PreviewFamilyAPIClient(), avatarUploadService: PreviewProfileAvatarUploadService())
    }

    /// LS-95 merge-review R1 M1(b)：帶著家庭狀態的 preview store。`SettingsView` 的「邀請家人」
    /// 列只在 `myFamily != nil` 才渲染（LS-107）——沒有這個工廠方法，`tap-target-check` 的
    /// harness 永遠量不到那顆列（golden run 的 `testSettingsView` 因此只點名了「登出」一顆，
    /// reviewer 實測確認）。同步呼叫 `seedMyFamilyForPreview`（見 `FamilyStore.swift`），不經過
    /// async fetch，沒有時序窗口。
    @MainActor
    static func preview(withFamily family: Family) -> FamilyStore {
        let store = FamilyStore(
            apiClient: PreviewFamilyAPIClient(), avatarUploadService: PreviewProfileAvatarUploadService()
        )
        store.seedMyFamilyForPreview(family)
        return store
    }
}
#endif
