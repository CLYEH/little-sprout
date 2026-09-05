#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `FamilyAPIClient`——不打真網路、不需要
/// `Config/Secrets.xcconfig`（同 `PreviewAuthService` 的角色，見該檔）。生產路徑一律用
/// `SupabaseFamilyAPIClient`。
/// LS-192 R2（merge-review R1 M8）：`PreviewFamilyAPIClient.listMembers` 預設樣本的「自己」
/// `userID` 固定值——不是 `private`：`TapTargetGateHarness+Family.swift`（另一個檔案）需要
/// 用同一個 id 呼叫 `FamilyStore.seedOwnerUserIDForPreview`，讓 `myRole` 解析成
/// `.owner`，才能讓成員列的動作選單在 harness 裡渲染，見該檔文件註解。
enum PreviewFamilySamples {
    static let selfUserID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
}

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

    /// R2（merge-review R1 M8／m4）：R1 文件註解宣稱「預設回傳兩位樣本成員」但實作回 `[]`，
    /// 導致 `FamilyMembersView.task` 的 `refreshMembers()` 蓋掉 harness／`#Preview` 用
    /// `seedMembersForPreview` 佈置的樣本，量到／看到的都是空清單（截圖 `LS-192-review-
    /// shot-03-light.png` 實測）。這裡讓實作對齊文件宣稱：預設回傳「自己（家庭管理者，`userID`
    /// 固定為 `PreviewFamilySamples.selfUserID`）＋一位一般成員」兩位樣本，呼叫端
    /// （`TapTargetGateHarness.familyMembersHost`）用 `seedOwnerUserIDForPreview
    /// (PreviewFamilySamples.selfUserID)` 對上同一個 id，才能讓「我是家庭管理者」視角的
    /// chevron 動作選單一開畫面就渲染。需要「唯一家庭管理者」等其他樣本的呼叫端改用
    /// `FamilyStore.seedMembersForPreview(_:)`（同步覆寫，同 `seedMyFamilyForPreview` 的既有
    /// 作法）——這支 async fetch 完成後仍會覆寫回預設值，只有本票目前唯一需要非預設樣本的
    /// 呼叫端（單元測試）改用 `StubFamilyAPIClient`，不受影響。
    func listMembers(familyID: UUID) async throws -> [FamilyMember] {
        [
            FamilyMember(
                userID: PreviewFamilySamples.selfUserID, role: .owner, displayName: "陳美玲", avatarURL: nil
            ),
            FamilyMember(userID: UUID(), role: .member, displayName: "陳阿公", avatarURL: nil)
        ]
    }

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
