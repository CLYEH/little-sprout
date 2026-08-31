import SwiftUI
import UIKit

/// 寶貝切換器（10／10b，`design/littlesprout.pen` `N 切換` R3 F9 定案）版式判斷：分段控制
/// （≤3，`ebuFg`）／下拉（>3 或 AX3，`xgx94`）之間怎麼選，用**寬度**判斷，不是數量判斷
/// ——Stress/10 壓測板證實 3 位真實長名字（陳彥廷／小饅頭／Emma Chen）就會把分段控制擠爆
/// （真控件 113pt/段，(345−6)/113≈3）。
enum ChildFilterLayout {
    /// AX3（`.accessibility3`）起一律強制下拉，不論寶貝數（LS-67 R1 A11y/10：分段版式在
    /// 40pt 字級下 3 個分段就會擠爆版面，下拉是唯一能撐住長輩最大字級的方案）。
    static func forcesDropdown(dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize >= .accessibility3
    }

    /// 「全部」＋每個寶貝一個 segment 的自然總寬（track 內距 6pt ＋ 每個 segment 的
    /// avatar／文字／內距）——對應 `ebuFg`／`Y3DMG` 節點的 padding／gap 值（見
    /// `design/littlesprout.pen`），不是憑空估的數字。
    static func requiredWidth(childNames: [String], dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let font = scaledBoldBodyFont(for: dynamicTypeSize)
        let trackPadding: CGFloat = 6 // `ebuFg.padding` 3pt，左右各一
        let horizontalInset: CGFloat = 32 // `Segment.padding` = ["$ctl-pad-md","$sp-item"]，兩側 $sp-item(16)
        let avatarWidth: CGFloat = 28
        let avatarGap: CGFloat = 6 // `$sp-tight`

        var total = trackPadding
        total += measure("全部", font: font) + horizontalInset
        for name in childNames {
            total += avatarWidth + avatarGap + measure(name, font: font) + horizontalInset
        }
        return total
    }

    /// 綜合寬度判斷＋AX3 強制：`availableWidth` 是切換器容器實際可用的寬度（螢幕寬減
    /// screen-pad 兩側）。
    static func shouldUseDropdown(
        childNames: [String],
        availableWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        if forcesDropdown(dynamicTypeSize: dynamicTypeSize) { return true }
        guard availableWidth > 0 else { return false }
        return requiredWidth(childNames: childNames, dynamicTypeSize: dynamicTypeSize) > availableWidth
    }

    private static func measure(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `$fs-body`（17pt，bold——分段選中態與下拉列都用粗體，取較寬的當估計值）依
    /// Dynamic Type 縮放的近似字級，對照 Apple HIG「Body」文字樣式的 Large Content 表
    /// （xSmall14/small15/medium16/large17/xLarge19/xxLarge21/xxxLarge23/AX1 28/AX2 33）。
    /// AX3 以上不會走到這個函式（`forcesDropdown` 已提前攔截），保守給一個不會再被用到的值。
    /// 用查表（不是 switch）純粹是為了讓 SwiftLint 的 cyclomatic_complexity 過關——12 個 case
    /// 的窮舉本身沒有分支邏輯，查表語意完全等價、更容易一眼看出是純數字對照表。
    private static let bodyPointSizes: [DynamicTypeSize: CGFloat] = [
        .xSmall: 14, .small: 15, .medium: 16, .large: 17,
        .xLarge: 19, .xxLarge: 21, .xxxLarge: 23,
        .accessibility1: 28, .accessibility2: 33,
        .accessibility3: 40, .accessibility4: 40, .accessibility5: 40
    ]

    private static func scaledBoldBodyFont(for size: DynamicTypeSize) -> UIFont {
        let base: CGFloat = 17
        let points = bodyPointSizes[size] ?? base
        return UIFont.systemFont(ofSize: points, weight: .bold)
    }
}
