import SwiftUI

/// LS-167：上傳佇列 sheet（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`／`16 · 深色`／
/// `A11y / 16 AX3`）。
///
/// **固定 detent**（`ImjbJ`／`Jxcmk`：實測值，取代設計過程中的錯字舊值）：一般字級 727pt、
/// AX3 1224pt——單一 `.height()` detent，沒有 `.medium`/`.large` 可拖曳切換（這是暫時性進度
/// HUD，不是要瀏覽的內容頁）；仍允許系統預設的下滑手勢關閉（`ImjbJ`：關閉後上傳在背景繼續，
/// 見 `UploadQueueStore` 檔頭）。
///
/// **與稿面差異：不設 `.presentationDragIndicator(.visible)`**——稿面畫了一條 Grabber 短線
/// （沖印品母題以外的系統慣例，其他既有 Sheet 如 `AttributionSheet` 也有）。push-gate 實測：
/// 只要顯式打開它，iOS 會把這顆系統 grabber 曝露成一個獨立的 accessibility 元件（label
/// 「表單控點」，量到 76×25pt），被 `tap-target-check.sh` 判成 <44pt 違規——這是 Apple 系統
/// 繪製的控制項，不是本票的自畫 View，沒有公開 API 能調整它的 hit-test 尺寸（同
/// `tap-target-exemptions.txt` 對 `WelcomeView` 官方 `SignInWithAppleButton` 的既有理由：
/// 系統元件、量測意義有限，但那裡是整支排除，這裡選擇直接不啟用這個系統元件，維持這個畫面
/// 100% 由本票程式碼決定的按鈕都保證 ≥44pt）。單一固定 detent 的 sheet 拿掉 grabber 不影響
/// 手勢下滑關閉——drag-to-dismiss 是系統行為，跟 drag indicator 的視覺顯示是否開啟無關。
///
/// **版面結構**：摘要區（標題／總數／續傳橫幅／重試列，pinned 頂）－ 44pt 具名斷點
/// （`AppSpacing.section`，`TVLkD`）－ 列表區（三語意群組，可捲動）－ hairline － Footer
/// （pinned 底）。稿面的「Rows Scroll Area 剛好卡在列與列之間」是 Pencil 靜態畫布用來預覽
/// 捲動提示的裁切手法（`pewpi`／`TVLkD`）；SwiftUI 用真正的 `ScrollView` 取代，內容超出
/// 固定高度時自然捲動，不需要重現那個裁切高度戲法（Rule 2 簡化：這是比稿面手法更簡單、行為
/// 更正確的等價實作）。
struct UploadQueueSheetView: View {
    let store: UploadQueueStore
    var onViewStorage: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            summarySection
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.block)
            ScrollView {
                rowsSection
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.top, AppSpacing.section)
                    .padding(.bottom, AppSpacing.block)
            }
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            footerButton
                .padding(.vertical, AppSpacing.item)
                .padding(.horizontal, AppSpacing.screenPad)
        }
        .background(Color.lsSurface)
        .presentationDetents([.height(sheetHeight)])
    }

    /// `Jxcmk`：一般字級 727、AX3 1224（實測值）。
    private var sheetHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 1224 : 727
    }

    // MARK: - 摘要區

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("正在新增照片").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    Text("還有 \(store.remainingCount) 張還沒完成")
                        .appNumericFont(.body, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                    if !breakdownText.isEmpty {
                        Text(breakdownText).appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                    }
                }
            }
            if store.resumedFromInterruption {
                resumeBanner
            }
            if store.retryableFailedCount > 0 {
                retryAllButton
            }
        }
    }

    /// 「N 張等候上傳、M 張上傳中」——零的那半不出現（`design/littlesprout.pen` 稿面只示範
    /// 兩者皆非零的樣本，稿面沒有畫「只剩上傳中、沒有等候中」這種局部樣本，這裡延伸同一組
    /// 語彙，記入 handoff）。
    private var breakdownText: String {
        var parts: [String] = []
        if store.waitingCount > 0 { parts.append("\(store.waitingCount) 張等候上傳") }
        if store.uploadingCount > 0 { parts.append("\(store.uploadingCount) 張上傳中") }
        return parts.joined(separator: "、")
    }

    private var resumeBanner: some View {
        HStack(spacing: AppSpacing.label) {
            Image(systemName: "arrow.counterclockwise").appIconFrame(.medium)
            Text("已接續先前中斷的上傳。").appFont(.note)
        }
        .foregroundStyle(Color.lsTextSecondary)
        .padding(.horizontal, AppSpacing.item)
        .padding(.vertical, AppSpacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    /// `iIkHT`：單一 outline 按鈕，`$accent-soft` 底＋外框，文案直接帶數量。
    private var retryAllButton: some View {
        Button {
            store.retryAllRetryable()
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                Text("重試這 \(store.retryableFailedCount) 張").appNumericFont(.body, weight: .bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
        }
        .foregroundStyle(Color.lsTextPrimary)
        .background(Color.lsAccentSoft, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
        )
    }

    // MARK: - 列表區

    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            ForEach(store.sections) { section in
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text(section.title).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                    ForEach(section.rows) { row in
                        UploadQueueRowView(
                            row: row, thumbnail: store.thumbnail(for: row.id),
                            onRetry: { store.retry(row.id) }, onViewStorage: onViewStorage
                        )
                    }
                }
            }
        }
    }

    // MARK: - Footer

    /// `ImjbJ`：使用者點了就代表接受「背景續傳」——sheet 直接 dismiss，`UploadQueueStore`
    /// 內飛行中的 `Task` 不受影響（見該檔檔頭「已知限制」段）。
    private var footerButton: some View {
        Button {
            dismiss()
        } label: {
            // `.contentShape(Rectangle())`：push-gate 實測沒有這行時 hit-test frame 會落在
            // 44.0pt 邊界附近的浮點誤差內被判違規（`TAP-TARGET-FAIL: … frame=354.0x44.0pt`）
            // ——同 `UploadQueueRowView` 兩顆行內按鈕的坑，`.frame` 需要這行才會決定性地成為
            // hit-test 形狀。
            Text("在背景繼續，關閉視窗")
                .appFont(.body, weight: .medium)
                .frame(maxWidth: .infinity, minHeight: 45)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
    }
}

#if DEBUG
#Preview("亮") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
}

#Preview("深色") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
    .preferredColorScheme(.dark)
}

#Preview("AX3") {
    Color.clear.sheet(isPresented: .constant(true)) {
        UploadQueueSheetView(store: .previewSample())
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

extension UploadQueueStore {
    /// Preview／harness 共用的代表性樣本——涵蓋三群、LS002 置頂、有進度百分比與無進度百分比
    /// 兩種上傳中列，對應 `design/littlesprout.pen` `Q7HrnF`／`g8Q2W`「全部狀態展開」參考板。
    static func previewSample() -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        let now = Date()
        func upload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        store.seedForPreview([
            .init(upload(), enqueuedAt: now.addingTimeInterval(-6 * 60), state: .failed(.quota)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-4 * 60), state: .failed(.network)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-5 * 60), state: .failed(.server)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-1 * 60), state: .waiting),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-2 * 60), state: .uploading(progress: 0.42)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-3 * 60), state: .completed),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-3.5 * 60), state: .completed)
        ])
        return store
    }
}
#endif
