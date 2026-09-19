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

    func upsertGrowthRecord(childID: UUID, input: GrowthMeasurementInput) async throws -> GrowthRecord {
        do {
            let params = UpsertGrowthRecordParams(
                id: input.id, childID: childID, measuredOn: BirthdayFormat.wireString(from: input.measuredOn),
                heightCm: input.heightCm, weightKg: input.weightKg, headCm: input.headCm, note: input.note
            )
            let response: PostgrestResponse<GrowthRecord> = try await client
                .rpc("upsert_growth_record", params: params)
                .execute()
            return response.value
        } catch {
            throw AppError.map(error)
        }
    }

    func deleteGrowthRecord(id: UUID) async throws {
        do {
            try await client.rpc("delete_growth_record", params: ["p_id": id]).execute()
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

/// `upsert_growth_record` 的 7 個具名參數在 SQL 端**全部沒有預設值**（見 migration）——同
/// `CreateChildParams`／`UpdateChildParams` 的既有理由（該檔文件註解），這裡手動實作
/// `encode(to:)`，`id`／`heightCm`／`weightKg`／`headCm`／`note` 一律用 `encode(_:forKey:)`
/// （不是 `encodeIfPresent`），`nil` 時送明確的 JSON `null`，讓 PostgREST 收到全部 7 個 key。
private struct UpsertGrowthRecordParams: Encodable {
    let id: UUID?
    let childID: UUID
    let measuredOn: String
    let heightCm: Double?
    let weightKg: Double?
    let headCm: Double?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case childID = "p_child_id"
        case measuredOn = "p_measured_on"
        case heightCm = "p_height_cm"
        case weightKg = "p_weight_kg"
        case headCm = "p_head_cm"
        case note = "p_note"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(childID, forKey: .childID)
        try container.encode(measuredOn, forKey: .measuredOn)
        try container.encode(heightCm, forKey: .heightCm)
        try container.encode(weightKg, forKey: .weightKg)
        try container.encode(headCm, forKey: .headCm)
        try container.encode(note, forKey: .note)
    }
}
