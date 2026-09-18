#if DEBUG
import SwiftUI

/// LS-312：寶貝詳情・成長區塊三支 harness host，從 `TapTargetGateHarness.swift` 拆出獨立
/// 檔案——同 `TapTargetGateHarness+Albums.swift` 文件註解點名的既有先例（加完會超過該檔
/// `function_body_length`／`file_length` 上限）。三支都不能標 `private`（同既有先例，`private`
/// 以檔案為界，`TapTargetGateHarness.hostView(for:)` 跨檔案存取不到）。
extension TapTargetGateHarness {
    /// 01 populated——示範資料集 6 筆量測（`GrowthStore.previewSeededWithDemoRecords()`，
    /// Notes `G1tRP9`），最新值卡三格／曲線卡 Segmented／資料點／「新增量測」／「查看全部
    /// 紀錄」都渲染出來，涵蓋逐元件 tap target 量測。
    @MainActor
    @ViewBuilder
    static var growthDetailPopulatedHost: some View {
        NavigationStack {
            ChildGrowthDetailView(previewGrowthStore: .previewSeededWithDemoRecords())
        }
    }

    /// 04 空狀態——`GrowthStore.preview()` 預設空陣列，量測「新增量測」鈕在空狀態下仍然可點
    /// （品牌硬約束：不得 `.disabled(`）。
    @MainActor
    @ViewBuilder
    static var growthDetailEmptyHost: some View {
        NavigationStack {
            ChildGrowthDetailView(previewGrowthStore: .preview(childName: "陳小軒"))
        }
    }

    /// LS-313：02 新增量測 sheet（真表單，取代 placeholder）——日期欄／三個量測欄／Save／
    /// Cancel 都是有代表性的可點元件；sheet 本身自帶 grabber（不是系統 `.presentationDragIndicator`，
    /// 見該檔文件註解），不需要包一層呈現 sheet 的容器就能直接量測。
    @MainActor
    @ViewBuilder
    static var growthMeasurementFormHost: some View {
        GrowthMeasurementFormView(growthStore: .preview())
    }

    /// LS-313：03 記錄列表（真清單，取代 placeholder）——`previewSeededWithDemoRecords()`
    /// 6 筆示範資料＋`currentUserID` 對齊 `GrowthStore.previewAuthorID`／`isFamilyOwner: true`，
    /// 讓每一列的滑動揭露（編輯／刪除）與點列開 `GrowthRecordActionsSheet` 都有代表性可量。
    /// `NavigationStack(path:)` 帶非空初始路徑的理由同舊版 placeholder host 文件註解（保留：
    /// 真實用法一律由 `NavigationLink` 推入，天生就有系統返回鍵；沒有這個技巧建出來的裸
    /// `NavigationStack { GrowthRecordsListView(...) }` 會被 merge-review R1 B1 的「0 個元件」
    /// 自檢抓到 root 沒有系統返回鍵）。
    @MainActor
    @ViewBuilder
    static var growthRecordsListHost: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationDestination(for: Bool.self) { _ in
                    GrowthRecordsListView(
                        growthStore: .previewSeededWithDemoRecords(), childName: "陳小安",
                        currentUserID: GrowthStore.previewAuthorID, isFamilyOwner: true
                    )
                }
        }
    }

    /// LS-313：03c 列操作表——`onEdit`／`onDelete` 皆非 nil（同 `growthRecordsListHost` 的
    /// `isFamilyOwner: true`＋`currentUserID` 對齊作者，代表「兩個動作都看得到」的情境），量
    /// 「編輯這筆紀錄」／「刪除這筆紀錄」／「取消」三列。
    @MainActor
    @ViewBuilder
    static var growthRecordActionsSheetHost: some View {
        Color.clear.sheet(isPresented: .constant(true)) {
            GrowthRecordActionsSheet(
                record: GrowthRecord(
                    id: UUID(), familyID: UUID(), childID: UUID(), authorID: GrowthStore.previewAuthorID,
                    measuredOn: BirthdayFormat.date(fromWireString: "2026-08-20")!,
                    heightCm: 78.5, weightKg: 9.6, headCm: 45.0, note: nil, createdAt: Date(), updatedAt: Date()
                ),
                onEdit: {}, onDelete: {}
            )
        }
    }
}
#endif
