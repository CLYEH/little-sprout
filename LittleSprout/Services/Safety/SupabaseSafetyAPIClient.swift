import Foundation
import Supabase

/// `SafetyAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseSafetyAPIClient: SafetyAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchContentAuthor(targetType: ContentTargetType, targetID: UUID) async throws -> UUID? {
        do {
            switch targetType {
            case .diary:
                let response: PostgrestResponse<[AuthorIDRow]> = try await client
                    .from("diaries").select("author_id").eq("id", value: targetID).execute()
                return response.value.first?.authorID
            case .album:
                let response: PostgrestResponse<[CreatedByRow]> = try await client
                    .from("albums").select("created_by").eq("id", value: targetID).execute()
                return response.value.first?.createdBy
            case .media:
                let response: PostgrestResponse<[UploadedByRow]> = try await client
                    .from("media").select("uploaded_by").eq("id", value: targetID).execute()
                return response.value.first?.uploadedBy
            case .comment:
                let response: PostgrestResponse<[AuthorIDRow]> = try await client
                    .from("comments").select("author_id").eq("id", value: targetID).execute()
                return response.value.first?.authorID
            }
        } catch {
            throw AppError.map(error)
        }
    }

    func reportContent(
        familyID: UUID, targetType: ContentTargetType, targetID: UUID, reason: ReportReason
    ) async throws {
        do {
            let params = ReportContentParams(
                familyID: familyID, targetType: targetType.rawValue, targetID: targetID, reason: reason.rawValue
            )
            try await client.rpc("report_content", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func blockUser(familyID: UUID, blockedID: UUID) async throws {
        do {
            let params = FamilyMemberPairParams(familyID: familyID, blockedID: blockedID)
            try await client.rpc("block_user", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func unblockUser(familyID: UUID, blockedID: UUID) async throws {
        do {
            let params = FamilyMemberPairParams(familyID: familyID, blockedID: blockedID)
            try await client.rpc("unblock_user", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func removeContentAsOwner(targetType: ContentTargetType, targetID: UUID) async throws {
        do {
            let params = RemoveContentParams(targetType: targetType.rawValue, targetID: targetID)
            try await client.rpc("remove_content_as_owner", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// LS-189 R2（merge-review R1 m1）：`.limit(50)` 上限——封鎖名單／收件匣本來就不該無限長，
    /// 超過 50 筆屬罕見情境，分頁留待後續票（收件匣／封鎖名單皆同理，見下）。
    func listBlockedUsers(familyID: UUID) async throws -> [BlockedUserRecord] {
        do {
            let response: PostgrestResponse<[BlockedUserRecord]> = try await client
                .from("blocked_users")
                .select("blocked_id, created_at")
                .eq("family_id", value: familyID)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    /// `.limit(50)`——見上方 `listBlockedUsers` 文件註解，同理。
    func listPendingReports(familyID: UUID) async throws -> [ContentReportRecord] {
        do {
            let response: PostgrestResponse<[ContentReportRecord]> = try await client
                .from("content_reports")
                .select("id, target_type, target_id, reporter_id, reason, status, created_at")
                .eq("family_id", value: familyID)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    /// 同 `SupabaseFamilyAPIClient+Profile.removeMember` 既有的「requireUpdatedRow」手法：
    /// `content_reports` 的 UPDATE policy 是 owner-only 的 RLS USING 過濾，非 owner 呼叫時
    /// PostgREST 回 200＋`[]`（合法執行、匹配 0 列），SDK 不會 throw——這裡明確把「0 列受影響」
    /// 轉成錯誤，不讓 UI 誤以為處理成功了。
    func markReportResolved(reportID: UUID) async throws {
        do {
            let response: PostgrestResponse<[ReportIDRow]> = try await client
                .from("content_reports")
                .update(["status": "resolved"])
                .eq("id", value: reportID)
                .select("id")
                .execute()
            guard !response.value.isEmpty else {
                throw AppError.rejected(message: "沒有權限處理這則檢舉，或這則檢舉已經被處理", code: "no_rows_updated")
            }
        } catch {
            throw AppError.map(error)
        }
    }

    /// LS-189 R2（merge-review R1 m1）：依 `targetType` 一次 `.in("id", values:)` 批次查，取代
    /// 原本呼叫端逐筆序列 await 的 N+1。`targetIDs` 為空直接回傳空字典（同既有 `fetchDiaries`
    /// 等既有慣例，見 `SupabaseTimelineAPIClient`），不多打一次不必要的請求。
    func fetchReportSnippets(targetType: ContentTargetType, targetIDs: [UUID]) async throws -> [UUID: String] {
        guard !targetIDs.isEmpty else { return [:] }
        do {
            switch targetType {
            case .diary:
                let response: PostgrestResponse<[IDBodyRow]> = try await client
                    .from("diaries").select("id, body").in("id", values: targetIDs).execute()
                return Dictionary(uniqueKeysWithValues: response.value.map { ($0.id, $0.body) })
            case .comment:
                let response: PostgrestResponse<[IDBodyRow]> = try await client
                    .from("comments").select("id, body").in("id", values: targetIDs).execute()
                return Dictionary(uniqueKeysWithValues: response.value.map { ($0.id, $0.body) })
            case .album:
                let response: PostgrestResponse<[IDTitleRow]> = try await client
                    .from("albums").select("id, title").in("id", values: targetIDs).execute()
                return Dictionary(uniqueKeysWithValues: response.value.map { ($0.id, $0.title) })
            case .media:
                // media 沒有文字內容欄位——呼叫端（`ReportInboxView`）依 `targetType` 顯示通用
                // 標籤（「一張照片或影片」），不需要額外一支查詢。
                return [:]
            }
        } catch {
            throw AppError.map(error)
        }
    }
}

private struct AuthorIDRow: Decodable {
    let authorID: UUID?
    enum CodingKeys: String, CodingKey { case authorID = "author_id" }
}

private struct CreatedByRow: Decodable {
    let createdBy: UUID?
    enum CodingKeys: String, CodingKey { case createdBy = "created_by" }
}

private struct UploadedByRow: Decodable {
    let uploadedBy: UUID?
    enum CodingKeys: String, CodingKey { case uploadedBy = "uploaded_by" }
}

private struct IDBodyRow: Decodable {
    let id: UUID
    let body: String
}

private struct IDTitleRow: Decodable {
    let id: UUID
    let title: String
}

private struct ReportIDRow: Decodable {
    let id: UUID
}

private struct ReportContentParams: Encodable {
    let familyID: UUID
    let targetType: String
    let targetID: UUID
    let reason: String

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case targetType = "p_target_type"
        case targetID = "p_target_id"
        case reason = "p_reason"
    }
}

private struct FamilyMemberPairParams: Encodable {
    let familyID: UUID
    let blockedID: UUID

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case blockedID = "p_blocked_id"
    }
}

private struct RemoveContentParams: Encodable {
    let targetType: String
    let targetID: UUID

    enum CodingKeys: String, CodingKey {
        case targetType = "p_target_type"
        case targetID = "p_target_id"
    }
}
