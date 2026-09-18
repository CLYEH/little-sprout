import SwiftUI

/// 03b 刪除紀錄確認（LS-313，`design/littlesprout.pen` Notes `h5BNyi`→`d4zid`，沿 LS-152
/// 操作表語彙）——`DeleteConfirmationSheet` 的成長紀錄變體，組好文案＋呼叫
/// `GrowthStore.delete(id:)`，同 `DiaryDeleteConfirmationSheet`／`CommentDeleteConfirmationSheet`
/// 的既有分工（該共用元件見其文件註解）。
///
/// 畫面級屬性（Notes `mfafV`→`C4hvXW`）：隱藏 Tab Bar ✗（sheet 呈現）；標題自訂 Head Title；
/// 釘底動作帶有（Confirm Delete／Cancel）；失敗文案鍵 42501（`DeleteConfirmationSheet` 預設的
/// `userFacingMessage(for:)` 已涵蓋，本票不需要另外對碼——成長紀錄的刪除失敗只有「你沒有權限」
/// 這一種語意，沒有 LS027 那種「已被移除、只有管理者能還原」的情境，因為刪除本身就是那個
/// 移除動作）；深色／AX3 沿用共用元件，未另畫分支。
struct GrowthRecordDeleteConfirmationSheet: View {
    let growthStore: GrowthStore
    let record: GrowthRecord
    var onDeleted: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要刪除\(record.measuredOnHistoryLabel)這筆紀錄嗎？",
            bodyText: bodyText,
            confirmLabel: "刪除這筆紀錄",
            confirmAction: confirmAction,
            onSuccess: onDeleted
        )
    }

    /// Notes `d4zid`：「這筆量測（身高 78.5 cm、體重 9.6 kg、頭圍 45.0 cm）會從成長曲線與紀錄
    /// 列表移除，家人也看不到。這個動作目前無法在 App 內復原。」——只列這筆記錄「有值」的項目
    /// （同 `GrowthHistoryRow.presentMetrics` 既有精神：缺值的項目不提）。
    private var bodyText: String {
        let parts = GrowthMetric.allCases.compactMap { metric -> String? in
            guard let value = metric.value(in: record) else { return nil }
            return "\(metric.label) \(metric.formattedValue(value)) \(metric.unit)"
        }
        let summary = parts.joined(separator: "、")
        return "這筆量測（\(summary)）會從成長曲線與紀錄列表移除，家人也看不到。這個動作目前無法在 App 內復原。"
    }

    /// `GrowthStore.delete(id:)` 是 Bool＋`deleteState` 的既有慣例（同型別 `refresh()`／
    /// `save(...)`），不是拋錯——這裡轉接成 `DeleteConfirmationSheet` 期待的 throwing 介面，
    /// 讓那支共用元件自己的錯誤呈現（`errorRow(_:)`）可以顯示 `AppError`，不需要另外接一層。
    private func confirmAction() async throws {
        guard await growthStore.delete(id: record.id) else {
            if case .failure(let error) = growthStore.deleteState { throw error }
            throw AppError.server(message: "刪除失敗", code: nil)
        }
    }
}

#if DEBUG
#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        GrowthRecordDeleteConfirmationSheet(
            growthStore: .previewSeededWithDemoRecords(),
            record: GrowthRecord(
                id: UUID(), familyID: UUID(), childID: UUID(), authorID: GrowthStore.previewAuthorID,
                measuredOn: BirthdayFormat.date(fromWireString: "2026-08-20")!,
                heightCm: 78.5, weightKg: 9.6, headCm: 45.0, note: nil, createdAt: Date(), updatedAt: Date()
            )
        )
    }
}
#endif
