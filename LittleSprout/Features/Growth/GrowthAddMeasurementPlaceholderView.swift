import SwiftUI

/// 「新增量測」sheet 的空殼承接畫面（LS-312 票文範圍 1：「本票只接入口——sheet 由 2／2
/// （LS-313）實作，本票以…空殼畫面承接，不得 disabled」）。02 新增量測 sheet 本身（表單／
/// Status Slot／Range Warning Slot）是 LS-313 的範圍，這裡只保證「新增量測」鈕永遠可點、點下去
/// 有畫面可看，不是死路。
///
/// 不用系統 `NavigationStack`＋`ToolbarItem(placement: .cancellationAction)`：同
/// `CreateAlbumView` 文件註解點名的既有教訓——nav bar bar button item 熱區不受
/// `.padding()`／`.contentShape()` 影響，實測只有 58×36pt，低於 44pt 下限（R1 模擬器實測，
/// `TapTargetGateTests.testGrowthAddMeasurementPlaceholderView` 抓到）。改用
/// `CreateChildView.footer`「主鈕＋純文字次要鈕」的既有慣例：「取消」是一般 body content
/// 裡的 Button，`.padding()` 對它的熱區才會生效。
struct GrowthAddMeasurementPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.item) {
            Spacer()
            Image(systemName: "ruler")
                .appIconFrame(.large)
                .foregroundStyle(Color.lsTextSecondary)
            Text("新增量測")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("即將推出")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.vertical, AppSpacing.item)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }
}

#Preview {
    GrowthAddMeasurementPlaceholderView()
}
