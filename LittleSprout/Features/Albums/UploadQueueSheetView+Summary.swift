import SwiftUI

/// `UploadQueueSheetView` 的摘要區（Head／續傳橫幅／重試槽）——拆檔理由：SwiftLint `file_length`／`type_body_length`。
/// 用到的 `@State`（`snapshot`／`headMinHeight`／`retrySlotHeight`）因此不能是 `private`（Swift 的 `private` 以檔案為界）。
extension UploadQueueSheetView {
    var summarySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            head
            // 續傳橫幅只在「打開時仍有進行中」的態出現（`k4oJhV`：resumedFromInterruption && inFlight>0）。
            if snapshot.mode == .progress && store.resumedFromInterruption {
                resumeBanner
            }
            // merge-review R2 F5：失敗數 > 1 才有批次列——單一失敗時那一列自己的「重試」鈕就夠了。LS-410：槽位在
            // 打開時決定；可重試數降到 0（都被標記移除）時槽內改成一行說明、保留槽高（`x2it3Q` Retry All Bar）。
            if snapshot.hasRetrySlot {
                retrySlot
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

    /// 標題＋主行（＋分項）。三態文案見 `UploadQueueSheetCopy`；Head 打開後量高、鎖 `minHeight`。
    private var head: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(title)
                .appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(UploadQueueSheetCopy.plain(title))
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                mainLine
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
                        .accessibilityLabel(UploadQueueSheetCopy.plain(breakdownText))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: headMinHeight > 0 ? headMinHeight : nil, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headMinHeight = max(headMinHeight, $0) }
    }

    private var title: String {
        switch snapshot.mode {
        case .progress: "正在新增照片"
        case .onlyFailed: UploadQueueSheetCopy.onlyFailedTitle(failed: store.failedCount)
        case .allDone: "照片都加好了"
        }
    }

    @ViewBuilder
    private var mainLine: some View {
        switch snapshot.mode {
        case .progress:
            Text("還有 \(store.remainingCount) 張還沒完成")
                .appNumericFont(.body, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .onlyFailed:
            secondaryMain(UploadQueueSheetCopy.onlyFailedMain(failed: store.failedCount))
        case .allDone:
            secondaryMain(UploadQueueSheetCopy.allDoneMain(completed: store.completedCount))
        }
    }

    private func secondaryMain(_ text: String) -> some View {
        Text(text)
            .appFont(.body).foregroundStyle(Color.lsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(UploadQueueSheetCopy.plain(text))
    }

    /// 「N 張等候上傳、M 張上傳中」——零的那半不出現（`design/littlesprout.pen` 稿面只示範
    /// 兩者皆非零的樣本，稿面沒有畫「只剩上傳中、沒有等候中」這種局部樣本，這裡延伸同一組
    /// 語彙，記入 handoff）。只有進行中態有分項。
    private var breakdownText: String {
        guard snapshot.mode == .progress else { return "" }
        return UploadQueueSheetCopy.breakdown(waiting: store.waitingCount, uploading: store.uploadingCount)
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

    /// 重試槽：有可重試的失敗＝`iIkHT` 的按鈕；都被標記移除了（`x2it3Q`）＝同一個槽位改一行說明、保留打開時的高度。
    @ViewBuilder
    private var retrySlot: some View {
        Group {
            if store.retryableFailedCount > 0 {
                retryAllButton
            } else {
                Text(UploadQueueSheetCopy.noRetry)
                    .appFont(.body).foregroundStyle(Color.lsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(UploadQueueSheetCopy.plain(UploadQueueSheetCopy.noRetry))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: retrySlotHeight > 0 ? retrySlotHeight : nil, alignment: .center)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { retrySlotHeight = max(retrySlotHeight, $0) }
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
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            // merge-review R5：見 `UploadQueueRowView.swift` 檔頭「merge-review R5（真正的
            // 根因）」段——CI 的 iOS 26.2+ 模擬器對 `.sheet` 內容套用 ≈0.9602 縮放，
            // `minHeight` 要 48 才能在縮放後仍 ≥44。這顆鈕目前的 padding＋內容高度從未被 CI
            // 抓到過，這裡一併補上是防禦性一致處理，不是修既有違規。
            .contentShape([.interaction, .accessibility], Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
        .background(Color.lsAccentSoft, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
        )
    }
}
