import Foundation

/// 對應 `public.family_role`（supabase/migrations/20260822120000_init_schema.sql）。
enum FamilyRole: String, Codable, Sendable {
    case owner
    case member
    case viewer

    /// LS-192：03 成員清單排序——owner 最前，其次 member，最後 viewer（稿面「Owner 標示
    /// 置頂」慣例）。不能直接用 `rawValue` 字母序（"member" < "owner" < "viewer"，不是
    /// 想要的順序），排序邏輯抽出來讓 `SupabaseFamilyAPIClient.listMembers` 與任何未來
    /// 呼叫端都套用同一個規則。
    var sortRank: Int {
        switch self {
        case .owner: return 0
        case .member: return 1
        case .viewer: return 2
        }
    }
}

/// 對應 `public.families` 的可讀欄位子集。刻意不投影 `storage_quota_bytes` /
/// `storage_used_bytes`——雖然 SELECT grant 沒有逐欄限制、讀得到，但本 client 目前不提供
/// 任何操作這兩欄的功能（§10-A 的成本防線只由 DB trigger 維護），不投影對稱地表達
/// 「這層 client 目前不處理額度」，避免呼叫端誤以為這裡有維護額度的邏輯。
struct Family: Equatable, Sendable, Decodable {
    let id: UUID
    let name: String
    let createdBy: UUID?
    let createdAt: Date
    let requireApproval: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case requireApproval = "require_approval"
    }
}

/// `get_family_quota` RPC 的結果（見
/// `supabase/migrations/20260903091317_report_block_rpc.sql` §7）——LS-188 09／09b 儲存空間頁
/// 用量條與已滿判定。刻意不放進 `Family`（見該型別文件註解「不投影額度欄位」）：這是另一支
/// RPC 的回傳列，不是 `families` 表本身的投影。
struct FamilyQuota: Equatable, Sendable, Decodable {
    let usedBytes: Int64
    let quotaBytes: Int64

    enum CodingKeys: String, CodingKey {
        case usedBytes = "storage_used_bytes"
        case quotaBytes = "storage_quota_bytes"
    }

    /// 0...1，`quotaBytes <= 0`（理論上不會，DB check 約束 `>= 0`，但 0 額度不該除零）時回傳
    /// 1（視同已滿，比顯示 NaN／崩潰安全）。
    var usedFraction: Double {
        guard quotaBytes > 0 else { return 1 }
        return min(1, max(0, Double(usedBytes) / Double(quotaBytes)))
    }

    /// 09b「已滿」態判定——`usedBytes >= quotaBytes`（LS002 觸發的同一條件，見
    /// `supabase/migrations/20260822120100_triggers.sql` §3 硬防線）。
    var isFull: Bool { usedBytes >= quotaBytes }
}

/// `request_join` RPC 的結果（見 supabase/migrations/20260823010000_join_approval.sql）：
/// 家庭開審核則得到待審申請，關審核則直接入家。
enum JoinRequestOutcome: Equatable, Sendable {
    case pending(requestID: UUID, familyID: UUID)
    case joined(familyID: UUID)
}

/// 對應 `public.invites` 可讀欄位子集——R1 F2/F4：`create_invite` RPC 只回傳 `code`，
/// 但撤銷（`revokeInvite`，需要 `id`）與顯示真實剩餘名額（`GeneratedInvite.remainingUses`，
/// 需要 `usedCount`）都得反查這張表。`invites` 沒有 `created_at` 欄位（見
/// `supabase/migrations/20260822120000_init_schema.sql`），`fetchLatestActiveInvite` 用
/// `expiresAt` 排序當替代——本 app 每支碼一律用固定 7 天期限（`FamilyStore
/// .defaultInviteValidityDays`），expires_at 遞增與建立時間遞增同序；日後若開放自訂期限，
/// 這個排序假設就不成立，屆時要補一個真正的 created_at 欄位。
struct InviteRecord: Equatable, Sendable, Decodable {
    let id: UUID
    let code: String
    let role: FamilyRole
    let maxUses: Int
    let usedCount: Int
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, code, role
        case maxUses = "max_uses"
        case usedCount = "used_count"
        case expiresAt = "expires_at"
    }
}

/// 已產生的邀請碼——R1 F2/F4 訂正：`create_invite` RPC 只回傳 `code`，但 `id`／`usedCount`
/// 現在一律從 `invites` 表反查回來（`FamilyAPIClient.createInvite` 文件註解），不再是「呼叫端
/// 自己組出來、剛產生完必為 0」的假值。`id` 是撤銷（`revokeInvite`）需要的鍵；`usedCount` 是
/// F4「還可用 N 次」要用真實剩餘量，兩者都不能只靠呼叫端自己組。移到這裡（原本在
/// `FamilyStore.swift`）：LS-192 讓主檔逼近 SwiftLint `file_length` 上限，這是純資料型別，跟
/// 這個檔案其餘 model 放在一起更合適。
struct GeneratedInvite: Equatable, Sendable {
    let id: UUID
    let code: String
    let role: FamilyRole
    let expiresAt: Date
    let maxUses: Int
    let usedCount: Int

    init(id: UUID, code: String, role: FamilyRole, expiresAt: Date, maxUses: Int, usedCount: Int) {
        self.id = id
        self.code = code
        self.role = role
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usedCount = usedCount
    }

    init(record: InviteRecord) {
        self.init(
            id: record.id,
            code: record.code,
            role: record.role,
            expiresAt: record.expiresAt,
            maxUses: record.maxUses,
            usedCount: record.usedCount
        )
    }

    /// 07 Pill「還可用 N 次」要顯示的值——R1 F4：過去這裡曾經直接顯示 `maxUses`，
    /// 永遠不會反映真的用掉幾次。`max(0, ...)`：`usedCount` 理論上不會大於 `maxUses`
    /// （DB `invites_uses_within_max` CHECK 約束），這裡只是防禦性地不顯示負數。
    var remainingUses: Int {
        max(0, maxUses - usedCount)
    }
}

/// 對應 `public.profiles` 可讀欄位子集（docs/API.md §3）——LS-192 / 02 顯示名稱與頭像編輯讀寫
/// 自己這一列；`avatarURL` 語意見 `ProfileAvatarPath` 文件註解（可能是 OAuth 公開網址，也可能
/// 是本票新增的自行上傳 Storage 路徑，兩者共用同一個文字欄位）。
struct Profile: Equatable, Sendable, Decodable {
    let id: UUID
    let displayName: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

/// `profiles.avatar_url`／`family_members.profiles.avatar_url` 共用同一個文字欄位表達兩種
/// 語意（docs/API.md §3 `profiles`）：
///   1. OAuth provider 給的公開頭像網址（`http`/`https` 開頭，`AsyncImage` 可直接載入，見既有
///      `InviteFamilyView+PendingApprovals.swift` 的 `applicantAvatar`）。
///   2. LS-192 新增的自行上傳頭像——重用 LS-169 `ChildAvatarUploadService` 同一套 Storage 路徑
///      形狀（`{family_id}/avatars/{uuid}.jpg`，見 `ChildAvatarUploadService
///      .uploadProfileAvatar`），沒有 URL scheme，需要簽名才能讀取（同 `children.avatar_url`
///      的既有慣例）。
/// 用有沒有 URL scheme 分辨兩者，不新增一個獨立欄位區分——改資料庫欄位是比這裡判斷式更大的
/// 變更面，且兩種語意天生互斥（Storage 路徑一律以 UUID 開頭，不可能剛好也是合法 `http(s)`
/// URL）。
enum ProfileAvatarPath {
    static func isStoragePath(_ value: String) -> Bool {
        URL(string: value)?.scheme == nil
    }
}

/// `family_members` 一列 join `profiles`（PostgREST FK 內嵌：`family_members.user_id`
/// references `profiles.id`，見 `supabase/migrations/20260822120000_init_schema.sql`）——
/// LS-192 / 03 家庭成員清單需要角色＋顯示名稱＋頭像一次讀出來，不需要另開一支 RPC：
/// `profiles_select` 的 `peer_profile_ids()` 分支本來就允許讀到同家庭任何人的
/// `display_name`／`avatar_url`（docs/API.md §3 `profiles`）。
struct FamilyMember: Equatable, Sendable, Decodable, Identifiable {
    let userID: UUID
    let role: FamilyRole
    let displayName: String
    let avatarURL: String?

    var id: UUID { userID }

    init(userID: UUID, role: FamilyRole, displayName: String, avatarURL: String?) {
        self.userID = userID
        self.role = role
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case profile = "profiles"
    }

    enum ProfileCodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(UUID.self, forKey: .userID)
        role = try container.decode(FamilyRole.self, forKey: .role)
        let profile = try container.nestedContainer(keyedBy: ProfileCodingKeys.self, forKey: .profile)
        displayName = try profile.decode(String.self, forKey: .displayName)
        avatarURL = try profile.decodeIfPresent(String.self, forKey: .avatarURL)
    }
}

/// `transfer_ownership(p_family_id, p_to_user_id)` RPC 的回傳列（LS-206：`returns table
/// (from_user_id uuid, from_role family_role, to_user_id uuid, to_role family_role)`）——
/// 呼叫成功後兩個角色的新值，`FamilyStore.transferOwnership` 用它就地更新本地 `members`，
/// 不必整份重查。
struct TransferOwnershipResult: Equatable, Sendable, Decodable {
    let fromUserID: UUID
    let fromRole: FamilyRole
    let toUserID: UUID
    let toRole: FamilyRole

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case fromRole = "from_role"
        case toUserID = "to_user_id"
        case toRole = "to_role"
    }
}

/// `list_join_requests` RPC 回傳列——owner 的待審清單。
struct PendingJoinRequest: Equatable, Sendable, Decodable {
    let requestID: UUID
    let familyID: UUID
    let applicantID: UUID
    let displayName: String
    let avatarURL: String?
    let role: FamilyRole
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case familyID = "family_id"
        case applicantID = "applicant_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case role
        case createdAt = "created_at"
    }
}

/// 對應 `public.join_request_status`（supabase/migrations/20260823010000_join_approval.sql）。
enum JoinRequestStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
    case withdrawn
}

/// `get_my_join_request` RPC 回傳列——申請人自己那一筆申請的狀態。
struct MyJoinRequest: Equatable, Sendable, Decodable {
    let requestID: UUID
    let familyID: UUID
    let familyName: String
    let status: JoinRequestStatus
    let createdAt: Date
    let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case familyID = "family_id"
        case familyName = "family_name"
        case status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}
