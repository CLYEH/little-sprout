import Foundation
import Supabase

/// `FamilyAPIClient` 的 Supabase 實作。方法 ↔ RPC 對照見協定檔的文件註解。
final class SupabaseFamilyAPIClient: FamilyAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func createFamily(name: String) async throws -> Family {
        // families_insert 的 RLS WITH CHECK 要求 created_by = auth.uid()（見
        // supabase/migrations/20260822120200_rls_policies.sql）：不送這欄、或送錯人的 id，
        // insert 都會被 RLS 擋下。與其讓呼叫端撞一個難懂的 RLS 錯誤，這裡先明確擋未登入。
        guard let userID = client.auth.currentSession?.user.id else {
            throw AppError.rejected(message: "尚未登入，無法建立家庭", code: "not_authenticated")
        }
        do {
            let payload = CreateFamilyPayload(name: name, createdBy: userID)
            let response: PostgrestResponse<Family> = try await client
                .from("families")
                .insert(payload)
                .select()
                .single()
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func updateFamilyName(familyID: UUID, name: String) async throws {
        do {
            try await client
                .from("families")
                .update(["name": name])
                .eq("id", value: familyID)
                .execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws {
        do {
            try await client
                .from("families")
                .update(["require_approval": requireApproval])
                .eq("id", value: familyID)
                .execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> String {
        do {
            let params = CreateInviteParams(
                familyID: familyID,
                role: role.rawValue,
                expiresAt: expiresAt,
                maxUses: maxUses
            )
            let response: PostgrestResponse<String> = try await client
                .rpc("create_invite", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func requestJoin(code: String) async throws -> JoinRequestOutcome {
        do {
            let response: PostgrestResponse<RequestJoinRow> = try await client
                .rpc("request_join", params: ["p_code": code])
                .single()
                .execute()
            return try response.value.outcome()
        } catch {
            throw AppError.map(error)
        }
    }

    func approveJoin(requestID: UUID) async throws {
        do {
            try await client.rpc("approve_join", params: ["p_request_id": requestID]).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func rejectJoin(requestID: UUID) async throws {
        do {
            try await client.rpc("reject_join", params: ["p_request_id": requestID]).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func withdrawJoin(requestID: UUID) async throws {
        do {
            try await client.rpc("withdraw_join", params: ["p_request_id": requestID]).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func listJoinRequests() async throws -> [PendingJoinRequest] {
        do {
            let response: PostgrestResponse<[PendingJoinRequest]> = try await client
                .rpc("list_join_requests")
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func myJoinRequest() async throws -> MyJoinRequest? {
        do {
            // 不用 .single()：0 筆是合法結果（從未申請過），.single() 會把 0 筆變成一個錯誤。
            let response: PostgrestResponse<[MyJoinRequest]> = try await client
                .rpc("get_my_join_request")
                .execute()
            return response.value.first
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

private struct CreateFamilyPayload: Encodable {
    let name: String
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case name
        case createdBy = "created_by"
    }
}

private struct CreateInviteParams: Encodable {
    let familyID: UUID
    let role: String
    let expiresAt: Date
    let maxUses: Int

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case role = "p_role"
        case expiresAt = "p_expires_at"
        case maxUses = "p_max_uses"
    }
}

/// `request_join` 回傳的原始列——`status` 是 'pending' 或 'joined' 兩種字面值（見
/// supabase/migrations/20260823010000_join_approval.sql 的 `return query select`）。
private struct RequestJoinRow: Decodable {
    let status: String
    let requestID: UUID?
    let familyID: UUID

    enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case familyID = "family_id"
    }

    func outcome() throws -> JoinRequestOutcome {
        switch status {
        case "pending":
            guard let requestID else {
                throw AppError.server(message: "request_join 回傳 pending 但缺少 request_id", code: nil)
            }
            return .pending(requestID: requestID, familyID: familyID)
        case "joined":
            return .joined(familyID: familyID)
        default:
            throw AppError.server(message: "request_join 回傳未知的 status：\(status)", code: nil)
        }
    }
}
