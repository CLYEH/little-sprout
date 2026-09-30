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

    /// LS-410：態與群標題列／重試槽的存在只在打開時判定一次（`UploadQueueSheetSnapshot`，brand #10 停留期間不搬版）。
    @State var snapshot: UploadQueueSheetSnapshot
    /// 打開後量到的摘要區 Head／重試槽實測高度——開著期間只增不減、鎖成 `minHeight`（`k4oJhV` R3：M＝0 過渡句、
    /// 「沒有能重試的照片」換掉內容也不搬版）。
    @State var headMinHeight: CGFloat = 0
    @State var retrySlotHeight: CGFloat = 0
    /// 每張失敗列（未標記時）的實測高度——標記當下墓碑列用它鎖列高（`FBoLL` R3）。
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @State private var confirmsBatchRemove = false

    init(store: UploadQueueStore, onViewStorage: @escaping () -> Void = {}) {
        self.store = store
        self.onViewStorage = onViewStorage
        _snapshot = State(initialValue: UploadQueueSheetSnapshot(store: store))
    }

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
        // 「移除這 N 張」要確認（`skC6Q`：批次一次標記多張，含本來回前景會自動重試的；單張有復原、不確認）。
        .confirmationDialog(
            UploadQueueSheetCopy.confirmTitle(count: store.failedCount), isPresented: $confirmsBatchRemove,
            titleVisibility: .visible
        ) {
            Button(UploadQueueSheetCopy.confirmAction(count: store.failedCount), role: .destructive) {
                store.markAllFailedRemoved()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(UploadQueueSheetCopy.confirmMessage)
        }
    }

    /// `Jxcmk`：一般字級 727、AX3 1224（實測值）。
    private var sheetHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 1224 : 727
    }

    /// `ap80H`／`Sxq8Z`：自畫 grabber，取代系統 `.presentationDragIndicator`（見檔頭「Grabber
    /// 改自畫」段）。純 `Shape`＋`accessibilityHidden`，`tap-target-check.sh` 不會量到它。
    /// merge-review R3 m1／m2：顏色對稿是 `$border`（不是 `$control-line`）；上緣留白
    /// （padding-top）是 24（`$sp-block`），不是 8。
    ///
    /// **grabber→標題間距（fix/LS-167-grabber-spacing，QA delta `788791f6` FAIL 後訂正）**：
    /// R4 N2 當時猜「`g3fRwP` 的 grabber 區域本身高 16pt」沒有對稿覆核過（本票期間 Pen
    /// 不可讀），拿掉了那個 16pt band，把 grabber→標題間距從原本的 ~30 改成 24。QA 這輪
    /// **直接開 Pen 量了兩塊獨立板 `rTEGf`／`Q7HrnF`，皆為 30pt**——R4 N2 拿掉的那個間距其實
    /// 是對的，R4 當時的懷疑（沒有 Pen 存取權，只能用節點結構猜）錯怪了它。這裡補回等效的
    /// 6pt（`AppSpacing.tight`／`$sp-tight`，對應稿面「Head 自身 `padding-top`」那段）：
    /// 24（grabber 上緣留白）＋5（capsule 高）＋6（這裡補的）＋24（summarySection 自己的
    /// `padding-top`）之後，capsule 下緣到標題的可視間距回到 30，與 `rTEGf`／`Q7HrnF` 兩塊板
    /// 的實測值一致。見 `UploadQueueSheetUITests
    /// .test_uploadQueueSheetNormal_grabberToTitleSpacingIsThirtyPoints`（相對量法，沿用
    /// footer 反推縮放係數那套，不用查證過的絕對常數）。
    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    // MARK: - 列表區

    @ViewBuilder
    private var rowsSection: some View {
        if snapshot.mode == .allDone {
            // `sq2SF`／`KYq7n`：全部完成＝3 欄縮圖格，照片是主角；不可點（C1a），「關閉」是唯一動作。
            let completed = store.sections.first { $0.kind == .completed }?.rows ?? []
            UploadQueueDoneGrid(items: completed.map {
                .init(id: $0.id, enqueuedAt: $0.enqueuedAt, thumbnail: store.thumbnail(for: $0.id))
            })
        } else {
            groupList
        }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            ForEach(store.sections) { section in
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    if section.kind == .failed {
                        failedHeader(title: section.title)
                    } else {
                        groupTitle(section.title)
                    }
                    ForEach(section.rows) { row in
                        queueRow(row)
                    }
                }
            }
        }
        // merge-review R3 M1：同 `summarySection` 的坑——常態下（例如只有一個群、列內容本身
        // 不夠寬）這個 VStack 會被外層預設 `.center` 對齊的 `body` VStack 水平置中，不是貼齊
        // `screenPad`。理由與修法同上，見該處註解。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// merge-review R2 F5：對稿——群標題是 `$text-secondary`，不是 `$text-primary`（群標題是分類語意，列內容才是主要
    /// 閱讀對象）。
    private func groupTitle(_ text: String) -> some View {
        Text(text).appFont(.body, weight: .bold).foregroundStyle(Color.lsTextSecondary)
    }

    /// 失敗群標題列：進行中態左「沒有成功」（②態和入口/標題同義，隱藏，`k4oJhV` R2 n1）、右「× 移除這 N 張」。
    /// 批次鈕只在打開時失敗數 >1 才建立這一列；之後失敗數降到 1 只把鈕的內容隱藏、列高保留（停留期間不增減行）。
    /// 空間不夠（AX3）改直排，同動作列（`fC2Rf`）。
    @ViewBuilder
    private func failedHeader(title: String) -> some View {
        let showsTitle = snapshot.mode == .progress
        if snapshot.hasBatchRemoveRow {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    if showsTitle { groupTitle(title) }
                    Spacer(minLength: 0)
                    batchRemoveButton(padded: true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if showsTitle { groupTitle(title) }
                    batchRemoveButton(padded: false)
                }
            }
        } else if showsTitle {
            groupTitle(title)
        }
    }

    @ViewBuilder
    private func batchRemoveButton(padded: Bool) -> some View {
        if snapshot.hasBatchRemoveRow {
            let visible = store.failedCount > 1
            let batchTitle = UploadQueueSheetCopy.batchRemoveTitle(count: store.failedCount)
            Button {
                confirmsBatchRemove = true
            } label: {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "xmark").appIconFrame(.medium).accessibilityHidden(true)
                    Text(batchTitle).appFont(.body, weight: .semibold)
                }
                .padding(.leading, padded ? AppSpacing.item : 0)
                .frame(minHeight: 48)
                .contentShape([.interaction, .accessibility], Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lsTextSecondary)
            .accessibilityLabel(UploadQueueSheetCopy.plain(batchTitle))
            .accessibilityIdentifier(QAAccessibilityID.uploadQueueRemoveAll)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
        }
    }

    private func queueRow(_ row: UploadQueueRow) -> some View {
        let isFailed: Bool = if case .failed = row.state { true } else { false }
        let isMarked = store.pendingRemovals.contains(row.id)
        return UploadQueueRowView(
            row: row, thumbnail: store.thumbnail(for: row.id),
            onRetry: { store.retry(row.id) }, onViewStorage: onViewStorage,
            onRemove: isFailed ? { store.markRemoved(row.id) } : nil,
            onUndo: { store.undoRemove(row.id) },
            isRemoved: isMarked, lockedHeight: rowHeights[row.id]
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // 只記「還沒標記」的失敗列——墓碑列是被鎖住的高度，不能反過來覆寫紀錄。
            if isFailed && !store.pendingRemovals.contains(row.id) { rowHeights[row.id] = height }
        }
    }

    // MARK: - Footer

    /// `ImjbJ`：使用者點了就代表接受「背景續傳」——sheet 直接 dismiss，`UploadQueueStore`
    /// 內飛行中的 `Task` 不受影響（見該檔檔頭「已知限制」段）。LS-410：進行中態才是「在背景繼續，關閉視窗」，其餘態「關閉」。
    /// `.fixedSize(vertical)`＋置中、不設 lineLimit：AX3 斷成兩行時被壓縮的該是 rowsSection 的 ScrollView，不是 footer（`fC2Rf`）。
    private var footerButton: some View {
        Button {
            dismiss()
        } label: {
            // merge-review R5：見 `UploadQueueRowView.swift` 檔頭「merge-review R5（真正的
            // 根因）」段——CI 的 iOS 26.2+ 模擬器對 `.sheet` 內容整體套用 ≈0.9602 縮放，
            // `minHeight: 45` 落地後量到 43.2pt，改 48（48 × 0.9602 ≈ 46.09）才安全過關。
            Text(snapshot.footerTitle)
                .appFont(.body, weight: .medium)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape([.interaction, .accessibility], Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
        .accessibilityLabel(UploadQueueSheetCopy.plain(snapshot.footerTitle))
    }
}
