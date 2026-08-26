import Foundation
import Supabase

/// `FamilyAPIClient` 的 Supabase 實作。方法 ↔ RPC 對照見協定檔的文件註解。
final class SupabaseFamilyAPIClient: FamilyAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func createFamily(name: String) async throws -> Family {
        do {
            // families_insert 的 RLS WITH CHECK 要求 created_by = auth.uid()（見
            // supabase/migrations/20260822120200_rls_policies.sql）。用 `client.auth.session`
            // 而不是同步的 `currentSession`（LS-49 PR #63 review F5／F12）：後者可能回傳過期的
            // session，`session` 是 async 版本，沒有 session 時 throw `AuthError.sessionMissing`
            // （被 AppError.map 收斂成 .rejected），過期時會先嘗試刷新——不必自己重造一個
            // 「未登入」的自訂錯誤碼。
            let session = try await client.auth.session
            // LS-107：docs/API.md §3 `profiles` 明定「登入後若尚未存在，登入流程要先 insert
            // 一列，display_name 必填」，但目前 repo 沒有任何登入路徑做這件事（`AuthStore`／
            // `SupabaseAuthService` 都不寫 `profiles`）。`families.created_by` 外鍵指到
            // `profiles(id)`，全新帳號第一次呼叫這裡若跳過這步會直接撞 23503
            // （foreign_key_violation）——在真正需要 profiles 列存在的第一個呼叫點補上，見
            // `ensureProfileExists` 文件註解。
            try await ensureProfileExists(userID: session.user.id, email: session.user.email)
            let payload = CreateFamilyPayload(name: name, createdBy: session.user.id)
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

    /// LS-107：見 `createFamily` 呼叫處的說明——這裡補的是「登入流程」原本該做但目前沒有任何
    /// 檔案做的事（docs/API.md §3 `profiles`）。刻意不動 `AuthStore`／`SupabaseAuthService`／
    /// 登入流程本身：`display_name` 從哪來是產品層問題（目前用 email 本地部分當預設值，見
    /// `EmailDisplayName`），改動範圍應留給專門處理「使用者顯示名稱」的票，這裡只解決「建立
    /// 家庭前 profiles 列必須存在」這個窄範圍的阻塞（見 handoff 風險欄）。
    ///
    /// `ignoreDuplicates: true`：已存在的 profiles 列（例如日後有專屬的顯示名稱設定畫面寫入過
    /// 真實姓名）不會被這裡的預設值覆蓋——底層送出 `Prefer: resolution=ignore-duplicates`，
    /// Postgres 端等同 `insert ... on conflict do nothing`，撞到既有列時完全不執行 UPDATE，
    /// 因此只需要 `profiles_insert` policy（`id = auth.uid()`），不需要 `profiles_update`。
    private func ensureProfileExists(userID: UUID, email: String?) async throws {
        let payload = ProfileUpsertPayload(id: userID, displayName: EmailDisplayName.derive(fromEmail: email) ?? "新成員")
        try await client
            .from("profiles")
            .upsert(payload, onConflict: "id", ignoreDuplicates: true)
            .execute()
    }

    func fetchMyFamily() async throws -> Family? {
        do {
            // families_select 的 RLS 把結果收斂到「id in (private.family_ids())」（見
            // supabase/migrations/20260822120200_rls_policies.sql）——呼叫者看不到自己不在
            // 其中的家庭，這裡不需要另外帶 user_id 篩選條件。Phase 1 單一家庭 MVP：一個使用者
            // 最多一個家庭，取 created_at 最早的一筆即可（正常情況下也只會有一筆）。
            let response: PostgrestResponse<[Family]> = try await client
                .from("families")
                .select()
                .order("created_at", ascending: true)
                .limit(1)
                .execute()
            return response.value.first
        } catch {
            throw AppError.map(error)
        }
    }

    func updateFamilyName(familyID: UUID, name: String) async throws {
        do {
            try await requireUpdatedRow(
                client
                    .from("families")
                    .update(["name": name])
                    .eq("id", value: familyID)
            )
        } catch {
            throw AppError.map(error)
        }
    }

    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws {
        do {
            try await requireUpdatedRow(
                client
                    .from("families")
                    .update(["require_approval": requireApproval])
                    .eq("id", value: familyID)
            )
        } catch {
            throw AppError.map(error)
        }
    }

    /// `families_update` policy 是 USING 過濾（不是 WITH CHECK 擋 INSERT 那種硬性拒絕）：
    /// 呼叫者不是該家庭 owner 時，UPDATE 語句本身合法執行，只是匹配 0 列，PostgREST 回
    /// 200 + `[]`，SDK 端完全不會 throw（LS-49 PR #63 review F2）。不擋這個情況的話，UI
    /// 會顯示「已儲存」但伺服器其實什麼都沒改。這裡把「0 列受影響」明確轉成錯誤。
    private func requireUpdatedRow(_ builder: PostgrestFilterBuilder) async throws {
        let response: PostgrestResponse<[Family]> = try await builder.execute()
        guard !response.value.isEmpty else {
            throw AppError.rejected(message: "沒有權限修改這個家庭，或家庭不存在", code: "no_rows_updated")
        }
    }

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> String {
        do {
            let params = CreateInviteParams(
                familyID: familyID,
                role: role.rawValue,
                // SDK 的預設 Date 編碼（JSONEncoder.supabase()）輸出的 ISO8601 字串不帶
                // 'Z'/offset（Helpers/DateFormatter.swift 的 `iso8601String` 沒有加時區指示），
                // Postgres 收到不帶時區的 timestamptz 字面值時會依資料庫 session 的
                // `timezone` 設定解讀，不保證是 UTC（LS-49 PR #63 review F8）。這裡自己用
                // `ISO8601DateFormatter` 明確帶 'Z'，不依賴後端 session timezone 剛好是 UTC。
                expiresAt: Self.iso8601String(from: expiresAt),
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

    /// 明確帶 'Z' 的 ISO8601 字串——見 createInvite 內的說明。每次呼叫都新建一個
    /// `ISO8601DateFormatter`（它不是 Sendable，不能用 static let 在多執行緒間共用），
    /// 這裡呼叫頻率是「使用者按一次建立邀請碼」等級，新建的成本可以忽略。
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

private struct ProfileUpsertPayload: Encodable {
    let id: UUID
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct CreateInviteParams: Encodable {
    let familyID: UUID
    let role: String
    let expiresAt: String
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
