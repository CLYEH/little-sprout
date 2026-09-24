import SwiftUI

/// 飲食圖鑑（LS-310／LS-379）的型別化 client 介面——本票只有讀取；寫入（`upsert_child_food_record`／
/// `delete_child_food_record`）在第一次記錄 sheet／記錄詳情票（LS-380／LS-381）加。
///
/// 方法 ↔ 後端對照（供 `docs/API.md` 對帳）：
///   - `listFoodCatalog` → 表 `food_catalog`（`select`，`active = true`，依 `sort_order`；全表唯讀，
///     `authenticated` 只有 SELECT，見 API.md §3）
///   - `listChildFoodRecords` → RPC `list_child_food_records(p_child_id)`（未刪、`first_tried_on desc`，
///     不分頁：274 種是天花板，見 API.md §4）
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的錯誤型別（同 `GrowthAPIClient`）。
protocol FoodAPIClient: Sendable {
    func listFoodCatalog() async throws -> [FoodCatalogItem]
    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord]
}

/// LS-379：app 根注入的飲食圖鑑 client（`LittleSproutApp.rootView` 的 `.environment(\.foodAPIClient, …)`）。
///
/// **刻意偏離既有「逐層 init 參數」慣例**（`growthAPIClient` 從 `LittleSproutApp` 經 `RootView`／
/// `AuthenticatedRootView`／`AuthenticatedGate`／`SectionTabView`／`SectionSplitView`／
/// `SectionContentView`／`ChildrenManagementView` 七層手傳）：本票的入口只是寶貝詳情裡的 DEBUG
/// 暫時入口（見 `ChildGrowthDetailView+FoodBookDebugEntry.swift`），為一個暫時入口改七個導覽型別
/// 的 init 與全部 preview／harness 呼叫點，是超出票面的導覽層重構。正式入口（LS-382）若要改回
/// 逐層傳參，只需要把讀取點換掉。預設 `nil`＝沒注入（preview／harness／單元測試），入口不顯示。
extension EnvironmentValues {
    @Entry var foodAPIClient: (any FoodAPIClient)?
}
