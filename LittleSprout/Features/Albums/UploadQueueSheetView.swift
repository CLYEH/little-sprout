import SwiftUI

/// LS-167：上傳佇列 sheet（`design/littlesprout.pen` `LS-142 / 16 上傳佇列`／`16 · 深色`／
/// `A11y / 16 AX3`）。
///
/// **固定 detent**（`ImjbJ`／`Jxcmk`：實測值，取代設計過程中的錯字舊值）：一般字級 727pt、
/// AX3 1224pt——單一 `.height()` detent，沒有 `.medium`/`.large` 可拖曳切換（這是暫時性進度
/// HUD，不是要瀏覽的內容頁）；仍允許系統預設的下滑手勢關閉（`ImjbJ`：關閉後上傳在背景繼續，
/// 見 `UploadQueueStore` 檔頭）。
///
/// **Grabber 改自畫（merge-review R2 F4）**：`.presentationDragIndicator(.visible)` 這個
/// 系統元件一旦啟用，iOS 會把它曝露成一個獨立的 accessibility 元件（label「表單控點」，量到
/// 76×25pt），被 `tap-target-check.sh` 判成 <44pt 違規——這是 Apple 系統繪製的控制項，沒有
/// 公開 API 能調整它的 hit-test 尺寸。改用稿面 `ap80H`／`Sxq8Z` 規格的自畫
/// `Capsule`（36×5pt，`$control-line`，`.accessibilityHidden(true)`）取代：純 `Shape`
/// 沒有任何內建 UIKit accessibility 語意，不會被量成按鈕，同時視覺上完全對齊稿面。單一固定
/// detent 的 sheet 不需要「拖曳切換 detent」的語意，這顆 grabber 純粹是視覺沖印品母題以外的
/// 系統慣例延續，不影響手勢下滑關閉（drag-to-dismiss 是系統行為，跟畫不畫得出視覺 grabber
/// 無關）。
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
            grabber
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

    /// `ap80H`／`Sxq8Z`：自畫 grabber，取代系統 `.presentationDragIndicator`（見檔頭「Grabber
    /// 改自畫」段）。純 `Shape`＋`accessibilityHidden`，`tap-target-check.sh` 不會量到它。
    /// merge-review R3 m1／m2：顏色對稿是 `$border`（不是 `$control-line`）；`g3fRwP` 的
    /// grabber 區域本身高 16pt（5pt Capsule 在其中垂直置中），上緣留白（padding-top）是 24
    /// （`$sp-block`），不是 8。
    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .frame(height: 16)
            .padding(.top, AppSpacing.block)
            .accessibilityHidden(true)
    }

    // MARK: - 摘要區

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("正在新增照片")
                    .appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    Text("還有 \(store.remainingCount) 張還沒完成")
                        .appNumericFont(.body, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !breakdownText.isEmpty {
                        // merge-review R2 F2 實測發現：加入續傳橫幅後，AX3 下 summarySection
                        // 的合計高度可能逼近固定 sheet 高度上限，VStack 會把「彈性最低」的
                        // Text 往下壓縮——沒有 `.fixedSize` 時這行會被截斷成「1 張等候上傳、
                        // 1 張…」，把「上傳中」吃掉。`.fixedSize(horizontal: false, vertical:
                        // true)` 強制這個 Text 用完整換行後的高度，把被壓縮的空間讓給設計上
                        // 本來就該可捲動、可以被壓縮的 `ScrollView`（`rowsSection`），不是讓
                        // 給不該被截斷的狀態文字。
                        Text(breakdownText)
                            .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if store.resumedFromInterruption {
                resumeBanner
            }
            // merge-review R2 F5：失敗數 > 1 才顯示批次列——單一失敗時那一列自己的「重試」
            // 鈕就夠了，疊一條只重試同一張的批次列沒有意義；`retryableFailedCount > 0` 仍要
            // 保留，避免「兩筆失敗但都是 LS002」顯示一顆「重試這 0 張」的空按鈕。
            if store.failedCount > 1 && store.retryableFailedCount > 0 {
                retryAllButton
            }
        }
        // merge-review R3 M1（major）：生產常態（無失敗、無續傳橫幅）下這個 VStack 裡完全
        // 沒有任何會撐寬到滿版的子元件（`retryAllButton`／`resumeBanner` 平常靠自己的
        // `.frame(maxWidth: .infinity)` 撐寬，但這兩個常態下都不會渲染）——`body` 最外層的
        // `VStack(spacing: 0)` 沒有指定 `alignment`（預設 `.center`，`grabber` 需要維持水平
        // 置中，不能整個外層改成 `.leading`），這個 VStack 因此會用自己最窄子項的寬度當
        // 整體寬度，被外層置中，reviewer 實測群標題 x 跑到 119.3（應為 24）。強制這裡
        // `.frame(maxWidth: .infinity, alignment: .leading)`，不依賴「裡面剛好有東西撐滿」
        // 這個易碎的隱性前提。
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // `alignment: .top`＋`.fixedSize`：同 `breakdownText` 踩到的同一個坑——AX3 沒有這兩個
        // 修飾詞時這句會被壓縮成「已接續先前中…」，且沒有 `.top` 對齊的話 icon 會卡在多行文字
        // 正中央，不是跟第一行文字對齊。
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "arrow.counterclockwise").appIconFrame(.medium)
            Text("已接續先前中斷的上傳。").appFont(.note).fixedSize(horizontal: false, vertical: true)
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
            // merge-review R4：目前的 padding＋內容高度在本機／CI 都還沒撞到 44pt 邊界（實測
            // 遠高於門檻），但既然同檔另外三顆鈕已經證明「純靠 padding＋字體度量湊高度」在
            // 不同 Xcode／iOS 版本上不可靠，這裡一併補上同一個不依賴字體度量的下限保證，
            // 不要等下次 CI 又在另一個版本組合上炸。
            .minimumTapTargetHeight()
            .contentShape(Rectangle())
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
                    // merge-review R2 F5：對稿——群標題是 `$text-secondary`，不是
                    // `$text-primary`（群標題是分類語意，列內容才是主要閱讀對象）。
                    Text(section.title).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextSecondary)
                    ForEach(section.rows) { row in
                        UploadQueueRowView(
                            row: row, thumbnail: store.thumbnail(for: row.id),
                            onRetry: { store.retry(row.id) }, onViewStorage: onViewStorage
                        )
                    }
                }
            }
        }
        // merge-review R3 M1：同 `summarySection` 的坑——常態下（例如只有一個群、列內容本身
        // 不夠寬）這個 VStack 會被外層預設 `.center` 對齊的 `body` VStack 水平置中，不是貼齊
        // `screenPad`。理由與修法同上，見該處註解。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    /// `ImjbJ`：使用者點了就代表接受「背景續傳」——sheet 直接 dismiss，`UploadQueueStore`
    /// 內飛行中的 `Task` 不受影響（見該檔檔頭「已知限制」段）。
    private var footerButton: some View {
        Button {
            dismiss()
        } label: {
            // merge-review R4：`.frame(minHeight:)` 在 CI runner（不同 Xcode／iOS SDK）量到
            // 43.2pt，本機量到 45pt——同一份程式碼在不同系統字體 metrics 下有落差。改用
            // `minimumTapTargetHeight`（純幾何 `Color.clear` 高度錨點，見
            // `UploadQueueRowView.swift` 檔頭「merge-review R4」段），不依賴字體行高。
            Text("在背景繼續，關閉視窗")
                .appFont(.body, weight: .medium)
                .frame(maxWidth: .infinity)
                .minimumTapTargetHeight()
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
        // merge-review R2 F2：續傳橫幅在稿面上是真實會出現的狀態，但沒有任何一組樣本把它
        // 設成 `true` 過——preview／DEBUG harness／QA 截圖因此永遠看不到它，等於這條路徑
        // 沒有人真的驗過長什麼樣子。這裡固定開啟，讓它跟其他三群狀態一樣「看得到」。
        store.resumedFromInterruption = true
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

    /// merge-review R3 M1：生產「常態」樣本——沒有任何失敗（不觸發 `retryAllButton`）、沒有
    /// 續傳橫幅（`resumedFromInterruption` 維持預設 `false`）、`uploading` 也不帶百分比。
    /// `previewSample()` 為了一次展示所有狀態，`summarySection` 裡永遠至少有一個會撐滿寬度
    /// 的子元件（續傳橫幅或重試列），因此測不出「完全沒有撐寬元件時整塊被置中」這個 bug
    /// （reviewer 在生產常態下量到群標題 x=119.3，應為 24）。這個樣本刻意最小、最平常，
    /// 專門用來釘住這個回歸。
    static func previewNormalSample() -> UploadQueueStore {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        let now = Date()
        func upload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        store.seedForPreview([
            .init(upload(), enqueuedAt: now.addingTimeInterval(-60), state: .waiting),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-30), state: .uploading(progress: nil)),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-180), state: .completed),
            .init(upload(), enqueuedAt: now.addingTimeInterval(-200), state: .completed)
        ])
        return store
    }
}
#endif
