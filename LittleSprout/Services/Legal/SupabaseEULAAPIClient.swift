import Foundation
import Supabase

/// `EULAAPIClient` 的 Supabase 實作。方法 ↔ RPC／資料表對照見協定檔的文件註解。
final class SupabaseEULAAPIClient: EULAAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// **不得**帶 `where id = true`（或任何引用到 `id` 的條件）——`docs/API.md` §4：欄位級
    /// 權限檢查涵蓋查詢裡任何位置引用到的欄位，`id` 沒有 `SELECT` 權限。`.single()` 只影響
    /// PostgREST 的 Accept header（要求剛好一列），不會替查詢加上任何欄位篩選，因此安全。
    func fetchCurrentVersion() async throws -> String {
        do {
            let response: PostgrestResponse<AppSettingsEULAVersionRow> = try await client
                .from("app_settings")
                .select("eula_version")
                .single()
                .execute()
            return response.value.eulaVersion
        } catch {
            throw AppError.map(error)
        }
    }

    /// `profiles` 是表級 SELECT（不像 `app_settings` 只開單一欄位），`id = auth.uid()` 一定
    /// 在 `private.peer_profile_ids()` 裡（見該函式：`select auth.uid() union ...`），不需要
    /// 先有家庭才查得到自己這一列。
    func fetchAcceptedVersion(userID: UUID) async throws -> String? {
        do {
            let response: PostgrestResponse<ProfileEULAAcceptedVersionRow> = try await client
                .from("profiles")
                .select("eula_accepted_version")
                .eq("id", value: userID)
                .single()
                .execute()
            return response.value.eulaAcceptedVersion
        } catch {
            throw AppError.map(error)
        }
    }

    func acceptEULA(version: String) async throws {
        do {
            try await client.rpc("accept_eula", params: ["p_version": version]).execute()
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

private struct AppSettingsEULAVersionRow: Decodable {
    let eulaVersion: String

    enum CodingKeys: String, CodingKey {
        case eulaVersion = "eula_version"
    }
}

private struct ProfileEULAAcceptedVersionRow: Decodable {
    let eulaAcceptedVersion: String?

    enum CodingKeys: String, CodingKey {
        case eulaAcceptedVersion = "eula_accepted_version"
    }
}
