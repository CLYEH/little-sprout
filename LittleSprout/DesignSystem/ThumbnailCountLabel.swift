import SwiftUI

/// 縮圖張數疊字（「還有 N 張」／「+N」）——`design/littlesprout.pen` Notes `sErBN`（LS-296 R3
/// MJ-1「縮圖張數疊字統一規則」）＋LS-439 Notes `F3GbnN`（Import 家族 More Cell 回填）。
/// `ImportMoreCell`（`$surface-2` 紙面）與 `DiaryCardView` 第三格暗蓋（75% 黑）共用這一個元件，
/// 兩者只差底與前景色（呼叫端給）、左右內距（Import `$sp-tight`，日記卡 0）。
///
/// 規格（逐條對 Notes）：
/// - 字級 `$fs-note`（`.note`，17pt 隨 Dynamic Type）粗體；不用 `$fs-imprint`（「還有幾張」是要讀的資訊）。
/// - 長短形由**可用寬度**決定，不看字級名稱：`ViewThatFits(in: .horizontal)`——放得下長形「還有 N 張」
///   就長形，放不下退短形「+N」；短形仍放不下（64pt 格 AX3 多位數、96 格 AX3 三位數）時
///   `lineLimit(1)＋minimumScaleFactor(0.5)` 收進格內，不裁字、不溢出。
/// - 長形數字兩側是 U+00A0（不斷行空白），「還有」「N」「張」不會被拆行或斷在數字旁。
/// - 左右內距在 `ViewThatFits` 外側，所以長短形判斷量的是「格寬 − 2×內距」（稿面 96 格 84、64 格 52）。
/// - VoiceOver：兩形一律讀長形（`spokenText`）。
struct ThumbnailCountLabel: View {
    let count: Int
    let foreground: Color
    /// 左右各一份內距——Import More Cell 傳 `AppSpacing.tight`（F3GbnN bPD0S：34 個 More Cell 統一），
    /// 日記卡暗蓋傳 0（sErBN 沿革：cmp/Card Diary CQpms 無內距）。
    var horizontalInset: CGFloat = 0

    /// 短形可縮到的下限（Notes sErBN：`minimumScaleFactor(0.5)`）。
    static let minimumScaleFactor: CGFloat = 0.5
    static let nbsp = "\u{00A0}"

    /// 長形「還有 N 張」：數字兩側 U+00A0。
    static func longText(_ count: Int) -> String { "還有\(nbsp)\(count)\(nbsp)張" }

    /// 短形「+N」。
    static func shortText(_ count: Int) -> String { "+\(count)" }

    /// VoiceOver 念的字：恆為長形，與視覺目前顯示哪一形無關。
    static func spokenText(_ count: Int) -> String { longText(count) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            text(Self.longText(count))
            text(Self.shortText(count))
                .minimumScaleFactor(Self.minimumScaleFactor)
        }
        .padding(.horizontal, horizontalInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenText(count))
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .appFont(.note, weight: .bold)
            .foregroundStyle(foreground)
            .lineLimit(1)
    }
}
