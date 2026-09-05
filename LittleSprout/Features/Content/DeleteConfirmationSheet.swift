import SwiftUI

/// LS-190（依 LS-152 稿 `oFRMc`／`Qs7iE`）：刪除單筆內容（日記／留言）的確認 sheet——通用
/// 版式，兩處呼叫端只有文案與實際 RPC 不同（`DiaryDeleteConfirmationSheet`／
/// `CommentDeleteConfirmationSheet` 各自組好文案與呼叫後轉呼叫這裡，見兩檔）。
///
/// **不承諾可還原**（LS-152 Notes IN-1 裁決）：`bodyText` 一律用「這個動作目前無法在 App 內
/// 復原」收尾，不寫「30 天內可還原」——本畫面群刻意沒有還原入口。
///
/// **Grabber 自畫**，同 `LegalDocumentSheet`／`UploadQueueSheetView` 既有理由（LS-167／
/// LS-191）：系統 `.presentationDragIndicator` 會被 `tap-target-check.sh` 判成獨立
/// accessibility 元件（label「表單控點」，量到 76×25pt）、判成 <44pt 違規；改用純
/// `Shape`＋`.accessibilityHidden(true)`，drag-to-dismiss 手勢不受影響（系統行為）。
///
/// **sheet 高度自我量測**：稿面把整份確認卡畫在一張全螢幕靜態畫布裡（`Scrim`＋`Sheet Wrap`
/// 絕對定位貼齊畫布底部），這是 Pencil 用來模擬「sheet 貼底、上方露出遮罩」視覺效果的手法
/// （同 `LegalDocumentSheet` iPad 置中卡片一節的既有裁決：靜態畫布結構不代表要在 SwiftUI
/// 手刻一層 Scrim，而是用系統 `.sheet()` 表達，稿面只是沒有「原生 sheet」這個概念可畫）。內容
/// 是固定結構（標題＋一段說明＋兩顆鈕），標題長度依呼叫端而定（日記變體會嵌入日記摘要，見
/// `DiaryDeleteConfirmationCopy`）——用 `.background(GeometryReader)` 量測內容實際高度後餵給
/// `.presentationDetents([.height(_:)])`，sheet 剛好貼合內容高度（含 Dynamic Type 放大後的
/// 高度），不需要為每個字級／文案長度組合窮舉一個像素常數（同 `LegalDocumentSheet` 用
/// `PreferenceKey` 量寬度的既有手法）。首幀用一個保守預設值渲染一次、量到真高後立刻更新——
/// 同 `LegalDocumentSheet` iPad 內距首幀過渡的既有記錄方式：理論上存在一次過渡，未逐幀量測，
/// 誠實記錄不誇稱保證不閃。
///
/// **可點元件 minHeight ≥48**（iOS 26.2+ sheet 內容套 ≈0.96 縮放，見票文硬規則）：兩顆按鈕的
/// `.frame(minHeight: 52)` 皆掛在 Button label 內容本身（不是掛在外層容器）——同
/// `CreateChildView.footer`「之後再說」鈕的既有先例：padding／frame 要掛在 label closure
/// 內才會被計入按鈕本身的 hit-test frame，掛在外層會變成 LS-95 `selfTestPaddingOutsideButton`
/// 那種「看起來有熱區、其實量不到」的漏網型。**實測誤差**：mobile-mcp（WDA）量到的
/// `frame.height` 比 `.frame(minHeight:)` 宣告值穩定少 2pt（`minHeight: 48` 量到 46、
/// `minHeight: 60` 量到 58）——不確定是 WDA 量測路徑本身的偏移還是別的原因，改成 52 留出
/// 緩衝，確定不論用哪個工具量都 ≥48；權威 gate（`tap-target-check.sh`／`TapTargetGateTests`，
/// XCUITest 原生 `element.frame`）在 `minHeight: 48` 時已經是 0 violation（≥44 達標），這裡
/// 只是加大緩衝，不是修一個 gate 未通過的問題。
struct DeleteConfirmationSheet: View {
    let headTitle: String
    let bodyText: String
    let confirmLabel: String
    let confirmAction: () async throws -> Void

    /// 見 `presentationDetents` 呼叫處的文件註解。
    private static let sheetHeightSafetyMargin: CGFloat = 8

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var error: AppError?
    @State private var measuredHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            grabber
            Text(headTitle)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, AppSpacing.tight)
            Text(bodyText)
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
            VStack(spacing: AppSpacing.group) {
                confirmButton
                cancelButton
                if let error {
                    errorRow(error)
                }
            }
        }
        .padding(.top, AppSpacing.block)
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.section)
        .frame(maxWidth: .infinity)
        .background(Color.lsSurface)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: DeleteConfirmationSheetHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(DeleteConfirmationSheetHeightKey.self) { newHeight in
            guard newHeight > 0 else { return }
            measuredHeight = newHeight
        }
        // +sheetHeightSafetyMargin：實測發現 sheet 高度剛好貼合量到的內容高度時，最底部的
        // 「取消」鈕會被裁掉幾個點的 hit-test 區（`GeometryReader` 量測與 `presentationDetents`
        // 實際套用之間的取整落差，非本檔可控）——量到的高度只是「至少要這麼高」的下限，多留一點
        // 緩衝比裁到最後一顆按鈕的熱區安全。
        .presentationDetents([.height(measuredHeight + Self.sheetHeightSafetyMargin)])
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .accessibilityHidden(true)
    }

    private var confirmButton: some View {
        Button(action: confirmTapped) {
            HStack(spacing: AppSpacing.label) {
                if isSubmitting {
                    ProgressView().tint(Color.lsDanger)
                } else {
                    Image(systemName: "trash").appIconFrame(.medium)
                }
                Text(confirmLabel).appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsDanger)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsDanger, lineWidth: 1.5)
            )
        }
        .disabled(isSubmitting)
    }

    private var cancelButton: some View {
        Button(action: cancelTapped) {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .disabled(isSubmitting)
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(error.userFacingMessage).appFont(.note)
        }
        .foregroundStyle(Color.lsDanger)
    }

    private func confirmTapped() {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await confirmAction()
                dismiss()
            } catch {
                self.error = AppError.map(error)
            }
        }
    }

    private func cancelTapped() {
        dismiss()
    }
}

/// 同 `LegalDocumentSheet` 的 `LegalDocumentSheetWidthKey`：`defaultValue = 0`＋`reduce` 用
/// `max`——沒有明確設這個 preference 的兄弟子樹貢獻 0，真正量到的 `GeometryReader` 永遠是唯一
/// 非零貢獻者，不受樹狀走訪順序影響（見該檔文件註解的 R4 段，同一種 wiring 陷阱，這裡直接套用
/// 已驗證過的解法）。
private struct DeleteConfirmationSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
