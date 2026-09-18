import Foundation

/// `upsert_growth_record` 的內容欄位（`p_id`／`p_measured_on`／`p_height_cm`／`p_weight_kg`／
/// `p_head_cm`／`p_note`）——`p_child_id` 不在這裡（新增分支才需要，且對編輯分支完全被 RPC
/// 忽略，見 `docs/API.md` §4 該 RPC 說明），另外當成 `upsertGrowthRecord(childID:input:)` 的
/// 第一個參數。抽成一個型別純粹是 SwiftLint `function_parameter_count`（上限 5）——不是語意上
/// 真的需要一個「輸入模型」物件，欄位維持 `var`＋逐一具名建構，同一般函式參數的使用方式。
struct GrowthMeasurementInput: Sendable {
    /// nil＝新增；非 nil＝編輯這一筆（`upsert_growth_record` 的 `p_id`）。
    var id: UUID?
    var measuredOn: Date
    var heightCm: Double?
    var weightKg: Double?
    var headCm: Double?
    var note: String?
}

/// 成長紀錄（LS-255／LS-312／LS-313）的型別化 client 介面。
///
/// 方法 ↔ RPC 對照（供 `docs/API.md` 對帳）：
///   - `listGrowthRecords` → RPC `list_growth_records(p_child_id, p_limit, p_before, p_before_id)`
///   - `upsertGrowthRecord` → RPC `upsert_growth_record(p_id, p_child_id, p_measured_on,
///     p_height_cm, p_weight_kg, p_head_cm, p_note)`
///   - `deleteGrowthRecord` → RPC `delete_growth_record(p_id)`
///
/// 錯誤一律映射為 `AppError`（見該檔），不直接往外拋 PostgREST 的錯誤型別。
protocol GrowthAPIClient: Sendable {
    /// 列出一個孩子的成長紀錄（未軟刪，依 `measured_on` 遞減）。`limit` 直接傳給
    /// `p_limit`——曲線／最新值卡／記錄列表要一次看到全部歷史，固定傳一個寬鬆上限（見
    /// `GrowthStore.fetchLimit`）；`p_before`／`p_before_id` 游標參數本票（LS-313）仍固定不帶
    /// （SQL 端有 `default null`，PostgREST 省略即可，不需要顯式送 `null`）——記錄列表直接讀
    /// `GrowthStore.records`（同一份已載入的資料，同 store），不需要另外分頁（YAGNI：MVP
    /// 資料量遠低於 `fetchLimit`，加分頁 UI 是本票沒有驗收條件要求的猜測性複雜度）。
    func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord]

    /// 新增（`input.id == nil`）或編輯內容（非 nil，僅原作者本人）一筆成長紀錄，回傳整列
    /// （含伺服器產生的 `id`／`createdAt`／`updatedAt`）供呼叫端直接更新本地 `records`，不需要
    /// 再重新整頁抓一次。
    func upsertGrowthRecord(childID: UUID, input: GrowthMeasurementInput) async throws -> GrowthRecord

    /// 軟刪一筆成長紀錄（作者本人或該家庭 owner）。
    func deleteGrowthRecord(id: UUID) async throws
}
