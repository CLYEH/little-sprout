import SwiftUI

/// 時間軸 Day Divider（LS-126 票文 Scope 1）——依日分組的日期章。
///
/// **已知風險（記於 handoff）**：稿面規格是「蓋章式」＋「Ghost 重影」（`design/littlesprout.pen`
/// Handoff Notes 板 `hsplj`），本票開工時 Pencil MCP 斷線、無法讀取該筆記的精確視覺規格
/// （傾斜角度、重影偏移量與透明度等）——這裡先落一版遵守 tokens／間距節奏但**不含**蓋章
/// 傾斜與重影效果的素樸版本（純日期文字＋髮絲線），視覺對齊需等 Pen 復連後另補一輪。
struct DayDividerView: View {
    let date: Date

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: AppSpacing.label) {
            Text(Self.label(for: date, twoLines: dynamicTypeSize.isAccessibilitySize))
                .appFont(.note, weight: .bold)
                .foregroundStyle(Color.lsTextSecondary)
            Rectangle()
                .fill(Color.lsBorder)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// 日期章文字。`twoLines`＝AX 字級（LS-464／LS-454 C3a，`design/littlesprout.pen` 規則卡 `lvdD5` `i1Jn6`）：
    /// 有附註時在「日期本體」與「附註」之間明確換行（「M月d日\n星期X」），最多兩行、字不縮小；
    /// 只有本體（「今天」「昨天」）一行。非 AX 字級輸出維持原樣。
    nonisolated static func label(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        twoLines: Bool
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.calendar = calendar
        formatter.dateFormat = "M月d日"
        let body = formatter.string(from: date)
        formatter.dateFormat = "EEEE"
        return body + (twoLines ? "\n" : " ") + formatter.string(from: date)
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
