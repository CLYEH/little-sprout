import Foundation
import Supabase

/// `ChildAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseChildAPIClient: ChildAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func listChildren(familyID: UUID) async throws -> [Child] {
        do {
            let response: PostgrestResponse<[Child]> = try await client
                .rpc("list_children", params: ["p_family_id": familyID])
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func createChild(familyID: UUID, name: String, birthday: Date, avatarURL: String?) async throws -> UUID {
        do {
            let params = CreateChildParams(
                familyID: familyID,
                name: name,
                birthday: BirthdayFormat.wireString(from: birthday),
                avatarURL: avatarURL
            )
            let response: PostgrestResponse<UUID> = try await client
                .rpc("create_child", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async throws {
        do {
            let params = UpdateChildParams(
                childID: childID,
                name: name,
                birthday: BirthdayFormat.wireString(from: birthday),
                avatarURL: avatarURL
            )
            try await client.rpc("update_child", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    func setChildDeleted(childID: UUID, deleted: Bool) async throws {
        do {
            let params = SetChildDeletedParams(childID: childID, deleted: deleted)
            try await client.rpc("set_child_deleted", params: params).execute()
        } catch {
            throw AppError.map(error)
        }
    }

    /// `family_members` 是「我所屬家庭的成員」直接可讀的表（見 `docs/API.md` §2），不需要 RPC。
    /// 不用 `.single()`：理論上呼叫者一定是該家庭成員（能看到這個畫面代表已經在家庭裡），但
    /// 防禦性地把「0 列」處理成 nil 而不是讓 `.single()` 對 0 列丟一個不好懂的 PostgREST 錯誤。
    func fetchMyRole(familyID: UUID) async throws -> FamilyRole? {
        do {
            let session = try await client.auth.session
            let response: PostgrestResponse<[MemberRoleRow]> = try await client
                .from("family_members")
                .select("role")
                .eq("family_id", value: familyID)
                .eq("user_id", value: session.user.id)
                .execute()
            return response.value.first?.role
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

/// `create_child`／`update_child` 這兩支 RPC 的 `p_avatar_url` 參數**沒有 SQL 預設值**
/// （見 migration），PostgREST 用「具名參數」比對函式簽章時要求全部 4 個參數都出現在
/// JSON body 裡——Swift 對 `Optional` 屬性自動合成的 `encode(to:)` 用的是
/// `encodeIfPresent`，`nil` 時會整個省略該 key（不是送 `null`），導致 PostgREST 找不到
/// 「只給 3 個具名參數」的函式簽章、回 404（PGRST202，本票 R1 手動模擬器驗證抓到的
/// 真實 bug，不是理論風險）。這裡手動實作 `encode(to:)`，`avatarURL` 一律用
/// `encode(_:forKey:)`（不是 `encodeIfPresent`），`nil` 時送明確的 JSON `null`，藉此
/// 讓 PostgREST 收到全部 4 個 key。
private struct CreateChildParams: Encodable {
    let familyID: UUID
    let name: String
    let birthday: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case familyID = "p_family_id"
        case name = "p_name"
        case birthday = "p_birthday"
        case avatarURL = "p_avatar_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(familyID, forKey: .familyID)
        try container.encode(name, forKey: .name)
        try container.encode(birthday, forKey: .birthday)
        try container.encode(avatarURL, forKey: .avatarURL)
    }
}

/// `p_avatar_url` 同 `CreateChildParams` 的理由，見該型別文件註解。
private struct UpdateChildParams: Encodable {
    let childID: UUID
    let name: String
    let birthday: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case childID = "p_child_id"
        case name = "p_name"
        case birthday = "p_birthday"
        case avatarURL = "p_avatar_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(childID, forKey: .childID)
        try container.encode(name, forKey: .name)
        try container.encode(birthday, forKey: .birthday)
        try container.encode(avatarURL, forKey: .avatarURL)
    }
}

private struct SetChildDeletedParams: Encodable {
    let childID: UUID
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case childID = "p_child_id"
        case deleted = "p_deleted"
    }
}

private struct MemberRoleRow: Decodable {
    let role: FamilyRole
}
