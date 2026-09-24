#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `FoodAPIClient`——不打真網路（同
/// `PreviewGrowthAPIClient` 的角色）。回傳完整 274 種目錄＋呼叫端給的記錄。
final class PreviewFoodAPIClient: FoodAPIClient, @unchecked Sendable {
    private let records: [ChildFoodRecord]

    init(records: [ChildFoodRecord] = []) {
        self.records = records
    }

    func listFoodCatalog() async throws -> [FoodCatalogItem] { PreviewFoodCatalog.items }

    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] { records }
}

extension FoodBookStore {
    /// LS-326 Notes `UsJkk` 示範資料集：陳小安（出生 2025-04-20，「今天」2026-08-20），已吃 38／274——
    /// 穀物根莖 10／16（品項與日期逐格照稿 `hWu6N`）、乳製品 1／7（優格 2026/5/2，照稿 `SYefI`）、
    /// 蔬菜 12、水果 9、肉魚蛋豆 5、台灣家常 1（稿面沒逐格畫，取該類 `sort_order` 前 N 樣、日期示意）。
    @MainActor
    static func previewSeededWithDemoRecords(childID: UUID = UUID()) -> FoodBookStore {
        let store = FoodBookStore(childID: childID, apiClient: PreviewFoodAPIClient())
        store.seedForPreview(catalog: PreviewFoodCatalog.items, records: demoRecords(childID: childID))
        return store
    }

    static func demoRecords(childID: UUID) -> [ChildFoodRecord] {
        let familyID = UUID()
        func record(_ foodID: String, _ day: String) -> ChildFoodRecord {
            let date = BirthdayFormat.date(fromWireString: day)!
            return ChildFoodRecord(
                id: UUID(), familyID: familyID, childID: childID, foodID: foodID, authorID: nil, firstTriedOn: date,
                mediaID: nil, note: nil, reaction: nil, createdAt: date, updatedAt: date
            )
        }
        let pinned: [(String, String)] = [
            ("rice_cereal", "2025-10-22"), ("rice_porridge", "2025-11-03"), ("oatmeal", "2026-01-05"),
            ("white_rice", "2026-02-14"), ("sweet_potato", "2025-11-10"), ("potato", "2025-12-01"),
            ("pumpkin", "2025-11-18"), ("corn", "2026-03-02"), ("noodles", "2026-04-11"), ("bread", "2026-06-08"),
            ("yogurt", "2026-05-02")
        ]
        let filler: [(FoodCategory, Int)] = [(.vegetable, 12), (.fruit, 9), (.protein, 5), (.twHome, 1)]
        let fillerIDs = filler.flatMap { category, count in
            PreviewFoodCatalog.items.filter { $0.category == category }.prefix(count).map(\.id)
        }
        return pinned.map { record($0.0, $0.1) } + fillerIDs.map { record($0, "2026-07-15") }
    }
}
#endif
