import SwiftUI

/// `cmp/Button Import`（`design/littlesprout.pen` frame `o8zYlX`，LS-315）——疊紙記號＋
/// 文字的次要動作鈕，「把相機膠卷照片匯入 app」的唯一入口樣式：`$surface` 底、`$control-line`
/// 1.5pt 描邊、`$radius-md` 圓角、gap 6、padding `[9.5, 12]`。三處 timeline instance（一般
/// 狀態 `e1cOqx` `YxuLr`／空狀態 `FUfqg` `wpGlp`／AX3 `aGkJ1` `VcvfI`）與相簿詳情「加入照片」
/// 第四使用點（Notes `TCs7A`：「之後的實作票應直接 ref cmp/Button Import，不得各自發明」，
/// LS-303 comment `c997f234` 記錄）共用同一個元件；`label` 依呼叫端情境不同（「匯入」／
/// 「加入照片」），元件本身的疊紙記號＋外框視覺一律不變。
///
/// Import Mark（`EJMa0`）＝前景 `Mark Front`（`v4CTZT`，代表一張相紙正面）＋兩片
/// `Mark Strip`（`H1Be6h`／`zwQeX`），三片皆 `$print-paper` 填色、`$paper-shadow` 1pt 描邊，
/// 真實間距讓每片露出 ≥2pt（Notes `TCs7A` R3／R4：VR 訂的「疊紙感」硬性門檻）。
///
/// AX3（`aGkJ1` 板 `VcvfI` descendants 覆寫）：記號整體以寬度基準等比放大 ×2.667
/// （12→32），不是連續 `@ScaledMetric` 曲線——同 `SectionTabBar.isAX3` 既有的兩態斷點慣例
/// （該檔文件註解：「`.pen` 只定案了『預設』與『AX3』兩個具名斷點的精確像素值...中間字級
/// 級距沿用預設值，不是每一階都內插」），中間字級與 AX4／AX5 皆沿用 AX3 的值。Label 文字
/// 走 `$fs-body` token（`.appFont(.body, weight: .semibold)`），隨 Dynamic Type 連續縮放，
/// 不需要另外覆寫（Notes `orXbN`：「隨 Dynamic Type 自動放大到 40，不需手動覆寫」）。
///
/// 稿面 `padding:[9.5,12]`＋17pt 字級的視覺高度落在 44pt 邊界附近——同 `TimelineView
/// .createMemoryButton` 既有手法，用不可見的 `.frame(minHeight:)` 撐大點擊區，不改變已經
/// 畫好的視覺 pill 尺寸。
struct ImportEntryButton: View {
    let label: String
    /// merge-review R2 M1：相簿詳情 Action Bar 版（`ve8YN`／`xcGEY`／`iXdTJ`／`EZqDj`）稿面
    /// instance 都是 `width:"fill_container"`——`ImportEntryButton` 本身天生 hug-content，
    /// 這顆旗標讓呼叫端可以選擇撐滿（Action Bar 版）或維持緊湊 pill（Header 三處 instance／
    /// iPad 行內版 `RbEqx` `width:"fit_content"`），不動元件本身的視覺 pill 尺寸。
    var fillsWidth = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAX3: Bool { dynamicTypeSize >= .accessibility3 }
    /// Import Mark 等比縮放係數——AX3 板寬度基準 32／預設寬度 12（Notes `orXbN`）。
    private var markScale: CGFloat { isAX3 ? 32.0 / 12.0 : 1 }
    private var markWidth: CGFloat { 12 * markScale }
    private var markFrontHeight: CGFloat { 10 * markScale }
    private var markStripHeight: CGFloat { 3 * markScale }
    private var markStripGap: CGFloat { 3.5 * markScale }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.tight) {
                importMark
                Text(label).appFont(.body, weight: .semibold).foregroundStyle(Color.lsTextPrimary)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.group)
            .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
            // merge-review R1 m2：緊貼 44pt 下限在 iOS 26.2+ ≈0.96 縮放 runtime 會跌破
            // tap-target 門檻（LS-167 同型）——抬到 48 留緩衝，不改變已畫好的視覺 pill 尺寸。
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }

    private var importMark: some View {
        VStack(spacing: 0) {
            markLayer(height: markFrontHeight)
            Spacer().frame(height: markStripGap)
            markLayer(height: markStripHeight)
            Spacer().frame(height: markStripGap)
            markLayer(height: markStripHeight)
        }
        .frame(width: markWidth)
    }

    private func markLayer(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.lsPrintPaper)
            .frame(width: markWidth, height: height)
            .overlay(Rectangle().strokeBorder(Color.lsPaperShadow, lineWidth: 1))
    }
}

#Preview("Default") {
    VStack(spacing: AppSpacing.item) {
        ImportEntryButton(label: "匯入", action: {})
        ImportEntryButton(label: "加入照片", action: {})
    }
    .padding()
}

#Preview("AX3") {
    ImportEntryButton(label: "匯入", action: {})
        .padding()
        .dynamicTypeSize(.accessibility3)
}
