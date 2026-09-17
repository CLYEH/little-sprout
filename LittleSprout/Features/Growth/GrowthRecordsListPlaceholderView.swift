import SwiftUI

/// 「查看全部記錄」的空殼承接畫面（LS-312 票文範圍 1，理由同
/// `GrowthAddMeasurementPlaceholderView`）。03 記錄列表（滑動編輯／刪除、Reveal Actions）是
/// 2／2（LS-313）的範圍；iPad（06）不出這個入口——歷史紀錄直接併入右欄（見 `GrowthHistorySection`
/// 文件註解），只有 iPhone（01）才會推到這裡。
struct GrowthRecordsListPlaceholderView: View {
    var body: some View {
        VStack(spacing: AppSpacing.item) {
            Image(systemName: "list.bullet.rectangle")
                .appIconFrame(.large)
                .foregroundStyle(Color.lsTextSecondary)
            Text("全部記錄")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("即將推出")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
        .navigationTitle("全部記錄")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        GrowthRecordsListPlaceholderView()
    }
}
