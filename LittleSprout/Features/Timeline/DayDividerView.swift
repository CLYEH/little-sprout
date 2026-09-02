import SwiftUI

/// 時間軸 Day Divider（LS-126 票文 Scope 1）——依日分組的日期章。
///
/// **已知風險（記於 handoff）**：稿面規格是「蓋章式」＋「Ghost 重影」（`design/littlesprout.pen`
/// Handoff Notes 板 `hsplj`），本票開工時 Pencil MCP 斷線、無法讀取該筆記的精確視覺規格
/// （傾斜角度、重影偏移量與透明度等）——這裡先落一版遵守 tokens／間距節奏但**不含**蓋章
/// 傾斜與重影效果的素樸版本（純日期文字＋髮絲線），視覺對齊需等 Pen 復連後另補一輪。
struct DayDividerView: View {
    let date: Date

    var body: some View {
        HStack(spacing: AppSpacing.label) {
            Text(dayLabel)
                .appFont(.note, weight: .bold)
                .foregroundStyle(Color.lsTextSecondary)
            Rectangle()
                .fill(Color.lsBorder)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.calendar = calendar
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: AppSpacing.section) {
        DayDividerView(date: Date())
        DayDividerView(date: Date().addingTimeInterval(-86400))
        DayDividerView(date: Date().addingTimeInterval(-86400 * 5))
    }
    .padding()
}
