import Foundation

/// 對應 `public.family_role`（supabase/migrations/20260822120000_init_schema.sql）。
enum FamilyRole: String, Codable, Sendable {
    case owner
    case member
    case viewer
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

/// `request_join` RPC 的結果（見 supabase/migrations/20260823010000_join_approval.sql）：
/// 家庭開審核則得到待審申請，關審核則直接入家。
enum JoinRequestOutcome: Equatable, Sendable {
    case pending(requestID: UUID, familyID: UUID)
    case joined(familyID: UUID)
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
