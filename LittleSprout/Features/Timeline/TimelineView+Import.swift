import SwiftUI

/// LS-303：相機膠卷批次匯入時間軸入口——抽到獨立檔案，同 `TimelineView+Comments.swift`
/// 既有拆檔理由（`TimelineView.swift` 本體已有卡片流／篩選／分頁三段邏輯，疊上這顆按鈕讓
/// `file_length` 超過 SwiftLint 上限）。
extension TimelineView {
    /// 票文範圍 1「時間軸『＋』」入口——次要樣式（`$surface-2` 底），跟 `createMemoryButton`
    /// （主要動作）視覺分級；本畫面無既有設計稿可對（`ImportOrganizeView` 起才有稿），外觀是
    /// 實作推定值，見 handoff 風險段。不是 `private`：`headerButtons`（`TimelineView.swift`）
    /// 跨檔案呼叫需要，同本檔慣例。
    var batchImportButton: some View {
        Button { showsBatchImport = true } label: {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "photo.stack").appIconFrame(.small).accessibilityHidden(true)
                Text("批次匯入").appFont(.body, weight: .semibold)
            }
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.item)
            .background(Color.lsSurface2, in: Capsule())
            .frame(minHeight: AppSpacing.section)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
    }
}
