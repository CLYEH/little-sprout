import Foundation

/// 成長紀錄（LS-255／LS-312）的型別化 client 介面。
///
/// 方法 ↔ RPC 對照（供 `docs/API.md` 對帳）：
///   - `listGrowthRecords` → RPC `list_growth_records(p_child_id, p_limit, p_before, p_before_id)`
///
/// 本票（LS-312）只讀——新增／編輯／刪除（`upsert_growth_record`／`delete_growth_record`）是
/// 2/2（LS-313）範圍，刻意不在這個協定預留寫入方法（YAGNI：介面該等真的要用時再加，現在猜
/// 只會猜錯形狀）。錯誤一律映射為 `AppError`（見該檔），不直接往外拋 PostgREST 的錯誤型別。
protocol GrowthAPIClient: Sendable {
    /// 列出一個孩子的成長紀錄（未軟刪，依 `measured_on` 遞減）。`limit` 直接傳給
    /// `p_limit`——本票不需要分頁（曲線／最新值卡要一次看到全部歷史），固定傳一個寬鬆上限；
    /// `p_before`／`p_before_id` 游標參數留給 2/2（LS-313）記錄列表分頁時才用，這裡固定
    /// 不帶（SQL 端有 `default null`，PostgREST 省略即可，不需要顯式送 `null`）。
    func listGrowthRecords(childID: UUID, limit: Int) async throws -> [GrowthRecord]
}
