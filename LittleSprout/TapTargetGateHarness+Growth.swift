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

    @MainActor
    @ViewBuilder
    static var growthAddMeasurementPlaceholderHost: some View {
        GrowthAddMeasurementPlaceholderView()
    }

    /// 純顯示、無內建 dismiss 元件的推入畫面（真實用法一律由 `NavigationLink` 推入，天生就有
    /// 系統返回鍵）——用 `NavigationStack(path:)` 帶一個非空初始路徑，讓畫面直接以「已推入」
    /// 狀態渲染，系統返回鍵因此存在，同真實推入路徑（同 `ChildGrowthDetailView.
    /// actionsCompact` 的 `NavigationLink` 用法）。merge-review R1 B1 的「0 個元件」自檢會抓到
    /// 沒有返回鍵的裸 `NavigationStack { GrowthRecordsListPlaceholderView() }`（root 沒有
    /// 系統返回鍵）。
    @MainActor
    @ViewBuilder
    static var growthRecordsListPlaceholderHost: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationDestination(for: Bool.self) { _ in
                    GrowthRecordsListPlaceholderView()
                }
        }
    }
}
#endif
