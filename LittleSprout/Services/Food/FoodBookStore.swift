import Foundation
import Observation

/// `FoodBookStore.refresh()` 的狀態機——同 `GrowthOperationState` 的形狀（本票只有讀取，不借用
/// 成長區塊的型別，避免兩個功能互相耦合）。
enum FoodBookLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failure(AppError)

    var isLoading: Bool { self == .loading }
}

/// 飲食圖鑑 02（LS-379）的 `@Observable` 狀態——view-scoped，每次推入圖鑑建一份（同 `GrowthStore`
/// 的角色分工）。
///
/// **目錄與記錄一次換**：`refresh()` 用 `async let` 平行抓 `food_catalog` 與 `list_child_food_records`，
/// 兩者都成功才一起寫進 `catalog`／`records`——只成功一半就寫，畫面會出現「目錄是新的、記錄是空的」
/// 的組合，吃過的格子全變灰，看起來像資料被清掉。失敗時保留上一份資料＋`loadState = .failure`。
@MainActor
@Observable
final class FoodBookStore {
    let childID: UUID
    private let apiClient: FoodAPIClient

    private(set) var catalog: [FoodCatalogItem] = []
    private(set) var records: [ChildFoodRecord] = []
    private(set) var loadState: FoodBookLoadState = .idle

    /// `food_id` → 那一筆記錄。partial unique index 保證同一寶貝同一食物最多一筆未刪記錄，
    /// `uniquingKeysWith` 只是防禦（取第一筆，不崩潰）。
    private var recordsByFoodID: [String: ChildFoodRecord] = [:]

    init(childID: UUID, apiClient: FoodAPIClient) {
        self.childID = childID
        self.apiClient = apiClient
    }

    /// 同 `GrowthStore.needsRebuild`：同一個孩子不重建（parent 重繪不清空重讀），換孩子才重建。
    static func needsRebuild(current: FoodBookStore?, forChildID childID: UUID) -> Bool {
        guard let current else { return true }
        return current.childID != childID
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !loadState.isLoading else { return false }
        loadState = .loading
        do {
            async let catalogResult = apiClient.listFoodCatalog()
            async let recordsResult = apiClient.listChildFoodRecords(childID: childID)
            let (newCatalog, newRecords) = try await (catalogResult, recordsResult)
            apply(catalog: newCatalog, records: newRecords)
            loadState = .loaded
            return true
        } catch {
            loadState = .failure(AppError.map(error))
            return false
        }
    }

    func record(for foodID: String) -> ChildFoodRecord? {
        recordsByFoodID[foodID]
    }

    /// 某一類的格子（`sort_order` 遞增，Notes `v5KLRQ`「格子順序＝sort_order」）。
    func items(in category: FoodCategory) -> [FoodCatalogItem] {
        catalog.filter { $0.category == category }
    }

    /// 計數句的分母：目錄裡（`active = true`）的全部品項。
    var totalCount: Int { catalog.count }

    /// 計數句的分子：只算目錄裡找得到的記錄——記錄指向已下架（`active = false`）的食物時不計入，
    /// 分子才不會大於分母、跟格子上看得到的紙片數一致。
    var triedCount: Int {
        catalog.reduce(0) { $0 + (recordsByFoodID[$1.id] == nil ? 0 : 1) }
    }

    func triedCount(in category: FoodCategory) -> Int {
        items(in: category).reduce(0) { $0 + (recordsByFoodID[$1.id] == nil ? 0 : 1) }
    }

    private func apply(catalog newCatalog: [FoodCatalogItem], records newRecords: [ChildFoodRecord]) {
        catalog = newCatalog.sorted { $0.sortOrder < $1.sortOrder }
        records = newRecords
        recordsByFoodID = Dictionary(newRecords.map { ($0.foodID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

#if DEBUG
extension FoodBookStore {
    /// 只給 `#Preview`／`TapTargetGateHarness` 用：直接種資料（同 `GrowthStore.seedForPreview`）。
    func seedForPreview(catalog: [FoodCatalogItem], records: [ChildFoodRecord]) {
        apply(catalog: catalog, records: records)
        loadState = .loaded
    }
}
#endif
