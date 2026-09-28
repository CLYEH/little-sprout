import SwiftUI

/// 飲食圖鑑（LS-310／LS-379）的型別化 client 介面——讀取（LS-379）＋第一次記錄 sheet 的寫入與照片來源
/// （LS-380）。
///
/// 方法 ↔ 後端對照（供 `docs/API.md` 對帳）：
///   - `listFoodCatalog` → 表 `food_catalog`（`select`，`active = true`，依 `sort_order`；全表唯讀，
///     `authenticated` 只有 SELECT，見 API.md §3）
///   - `listChildFoodRecords` → RPC `list_child_food_records(p_child_id)`（未刪、`first_tried_on desc`，
///     不分頁：274 種是天花板，見 API.md §4）
///   - `upsertChildFoodRecord` → RPC `upsert_child_food_record`（6 個具名參數全送，自然鍵 upsert，API.md §4）
///   - `deleteChildFoodRecord` → RPC `delete_child_food_record(p_id)`（軟刪，作者本人或 owner）
///   - `listFamilyPhotos`／`fetchFamilyPhoto` → 表 `media`（`type = photo`、`deleted_at is null`、該寶貝的
///     `family_id`；`media_select` RLS 另外會讓上傳者看到自己已軟刪的列，所以 `deleted_at` 要自己濾）
///   - `signedURLs` → Storage `media` bucket `createSignedURLs`（縮圖路徑）
///   - `uploadPhoto` → 既有 `MediaUploadService.uploadPhoto`（Storage 原檔＋縮圖 → `media` 列，同日記）
///
/// 錯誤一律映射為 `AppError`，不直接往外拋 PostgREST 的錯誤型別（同 `GrowthAPIClient`）。
protocol FoodAPIClient: Sendable {
    func listFoodCatalog() async throws -> [FoodCatalogItem]
    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord]
    func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord
    func deleteChildFoodRecord(id: UUID) async throws
    /// 該寶貝所屬家庭的照片（新到舊，最多 `FamilyPhotoQuery.limit` 張，見該常數）。
    func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto]
    /// 編輯既有記錄（03b）時回填照片縮圖用；已軟刪或看不到＝nil。
    func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto?
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL]
    /// 「從手機加入」：上傳到該寶貝所屬家庭，回傳新建 `media` 列的 id。
    func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID
}

/// 03d 一次最多列多少張家庭照片（`created_at` 新到舊）。不分頁：這是「挑一張最近的照片」的選擇器，
/// 不是完整相簿瀏覽（完整瀏覽在相簿分頁）；超過這個量的舊照片不會出現在 03d，要用的話走「從手機加入」。
enum FamilyPhotoQuery {
    static let limit = 300
}

/// LS-379：app 根注入的飲食圖鑑 client（`LittleSproutApp.rootView` 的 `.environment(\.foodAPIClient, …)`）。
///
/// **刻意偏離既有「逐層 init 參數」慣例**（`growthAPIClient` 從 `LittleSproutApp` 經 `RootView`／
/// `AuthenticatedRootView`／`AuthenticatedGate`／`SectionTabView`／`SectionSplitView`／
/// `SectionContentView`／`ChildrenManagementView` 七層手傳）：LS-379 當時入口只是 DEBUG 暫時入口，
/// 為它改七個導覽型別的 init 與全部 preview／harness 呼叫點是超出票面的導覽層重構。LS-382 正式入口
/// （`ChildGrowthDetailView+FoodBook.swift`）沿用同一個讀取點，未改回逐層傳參（LS-381 的
/// `foodRecordDetailAPIClient` 也走 environment）。預設 `nil`＝沒注入（preview／harness／單元測試），入口不顯示。
extension EnvironmentValues {
    @Entry var foodAPIClient: (any FoodAPIClient)?
}
