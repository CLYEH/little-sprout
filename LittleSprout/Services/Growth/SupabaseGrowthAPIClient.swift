import Foundation
import Supabase

/// `GrowthAPIClient` 的 Supabase 實作。方法 ↔ RPC 對照見協定檔的文件註解。
final class SupabaseGrowthAPIClient: GrowthAPIClient {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] {
        do {
            let params = ListGrowthRecordsParams(childID: childID, limit: limit)
            let response: PostgrestResponse<[GrowthRecord]> = try await client
                .rpc("list_growth_records", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }
}

// MARK: - Wire payloads

/// `p_before`／`p_before_id` 兩個具名參數在 SQL 端有 `default null`（見
/// `supabase/migrations/20260913065021_growth_records.sql`），跟 `ChildAPIClient`
/// 的 `CreateChildParams`（`p_avatar_url` 沒有 SQL 預設值）不是同一種情境——這裡可以用
/// Swift 合成的 `Encodable`，兩個游標參數本票固定不帶，省略即可讓 PostgREST 落回 SQL 預設值。
private struct ListGrowthRecordsParams: Encodable {
    let childID: UUID
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case childID = "p_child_id"
        case limit = "p_limit"
    }
}
