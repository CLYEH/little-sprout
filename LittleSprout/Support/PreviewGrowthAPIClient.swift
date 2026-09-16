#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `GrowthAPIClient`——不打真網路
/// （同 `PreviewChildAPIClient` 的角色，見該檔）。生產路徑一律用 `SupabaseGrowthAPIClient`。
private final class PreviewGrowthAPIClient: GrowthAPIClient, @unchecked Sendable {
    func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord] { [] }
}

extension GrowthStore {
    @MainActor
    static func preview(
        childID: UUID = UUID(), childName: String = "陳小安",
        childBirthday: Date = BirthdayFormat.date(fromWireString: "2025-04-20")!
    ) -> GrowthStore {
        GrowthStore(
            childID: childID, childName: childName, childBirthday: childBirthday,
            apiClient: PreviewGrowthAPIClient()
        )
    }

    /// Notes 統一示範資料集（`G1tRP9`）：陳小安，「今天」＝2026-08-20，出生 2025-04-20，
    /// 6 筆量測月齡 1/4/7/10/13/16（每 3 個月一筆，13mo 僅頭圍）——01／06 populated harness
    /// host／截圖對稿都用這組資料，逐字對齊 Notes 數值。
    @MainActor
    static func previewSeededWithDemoRecords(
        childID: UUID = UUID(), childName: String = "陳小安"
    ) -> GrowthStore {
        let store = GrowthStore.preview(childID: childID, childName: childName)
        let familyID = UUID()
        let authorID = UUID()
        func record(_ measuredOn: String, height: Double?, weight: Double?, head: Double?) -> GrowthRecord {
            let date = BirthdayFormat.date(fromWireString: measuredOn)!
            return GrowthRecord(
                id: UUID(), familyID: familyID, childID: childID, authorID: authorID, measuredOn: date,
                heightCm: height, weightKg: weight, headCm: head, note: nil, createdAt: date, updatedAt: date
            )
        }
        store.seedForPreview(records: [
            record("2025-05-20", height: 52.0, weight: 4.2, head: 37.5),
            record("2025-08-20", height: 62.5, weight: 6.8, head: 40.8),
            record("2025-11-20", height: 68.5, weight: 7.9, head: 42.6),
            record("2026-02-20", height: 73.0, weight: 8.7, head: 43.7),
            record("2026-05-20", height: nil, weight: nil, head: 44.4),
            record("2026-08-20", height: 78.5, weight: 9.6, head: 45.0)
        ])
        return store
    }
}
#endif
