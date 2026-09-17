import SwiftUI

/// 匯入進度頁（`design/littlesprout.pen` Import `04 匯入進度 (iPhone)` `YfOUJ`／深色 `y2Qsy`／
/// AX3 `Fgezb`／iPad `vOgRq`；LS-251 Notes「畫面級屬性」04 列）——`ImportBatchFlowContainer`
/// 用 `.fullScreenCover` 呈現整條批次匯入流程，本畫面是流程中段的一個內部狀態（見該檔文件
/// 註解），全螢幕蓋版本身已經蓋掉 `RootView` 的 Tab Bar；自訂 Nav Row＋自訂標題（Body 內的
/// 大標題文字，不用系統 `.navigationTitle`，同 `ImportPermissionDeniedView` 既有慣例）。
///
/// **未走 QA-GATE 標記**：同 `ImportOrganizeView` 檔頭理由——本畫面由 `AlbumDetailView` 觸發
/// 的批次匯入流程內部轉場而來，不是掛在 `RootView`／`RootView+*.swift` 的登入後全屏 gate。
///
/// **Queue Row 逐一比照 LS-142**（LS-251 Notes「與 LS-142 佇列的邊界」）：直接重用
/// `UploadQueueRowView`／`UploadQueueGrouping`（同一套三語意群組：沒有成功／正在進行／
/// 已完成），本畫面新增的只有 Total Progress Card 與 Nav Row 的「取消匯入」＋04b 確認。
struct Import04ProgressView: View {
    let session: ImportBatchSession
    let store: UploadQueueStore
    var onViewStorage: () -> Void = {}
    /// Action Bar「在背景繼續，關閉視窗」——結束整條批次匯入流程，佇列在背景繼續（同
    /// `UploadQueueSheetView.footerButton` 既有理由，這裡沒有 `.sheet`／`dismiss()` 環境值可
    /// 用，改由呼叫端決定「結束流程」的意思，見 `ImportBatchFlowContainer`）。
    let onLeaveInBackground: () -> Void
    /// 全部批次項目都到終局狀態（完成或失敗）時呼叫一次——轉場到 05 完成摘要（LS-251 Notes
    /// 「狀態機」段：「④摘要：完成…進入 05」）。
    let onAllItemsFinished: () -> Void
    /// 04b「取消匯入」確認後呼叫——批次項目已從佇列移除（`onConfirmCancel` 內部已呼叫
    /// `store.cancelPendingImportItems`），流程結束。
    let onCancelledImport: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsCancelConfirm = false

    private var batchIDs: Set<UUID> { session.entryIDSet }
    private var batchRows: [UploadQueueRow] { store.rows(in: batchIDs) }
    private var completedCount: Int { batchRows.count { if case .completed = $0.state { true } else { false } } }
    private var failedCount: Int { batchRows.count { if case .failed = $0.state { true } else { false } } }
    private var processedCount: Int { completedCount + failedCount }
    private var uploadingOrWaitingCount: Int { batchRows.count - processedCount }
    /// merge-review R1 M2：讀不到／不支援格式的 asset 從不進 `batchRows`（不會有 entry），
    /// 只靠 `processedCount` 算「已處理 N/M 張」會讓 N 永遠卡在比 M 少 `droppedCount` 那麼多，
    /// 進度條永遠到不了滿——這裡把 `droppedCount` 併入「已處理」的分子（它們已經是終局結果，
    /// 不是還在等），下面的「未加入 D 張」另一行講清楚這裡面有幾張是失敗／未進佇列。
    private var droppedCount: Int { session.droppedCount }
    private var displayProcessedCount: Int { processedCount + droppedCount }
    /// 04 進度卡「已處理 N/M 張」的 M——見 `ImportBatchSession.expectedAssetCount` 文件註解
    /// 「已知限制」（Live Photo 展開可能讓 `batchRows.count` 超過這個數字）。
    private var expectedTotal: Int { session.expectedAssetCount }
    private var progressFraction: Double {
        guard expectedTotal > 0 else { return 1 }
        return min(Double(displayProcessedCount) / Double(expectedTotal), 1)
    }
    private var retryableFailedCount: Int {
        batchRows.count { row in
            if case .failed(let reason) = row.state { return reason.isRetryable }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("正在匯入照片")
                        .appFont(.display, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Color.clear.frame(height: AppSpacing.block)
                    totalProgressCard
                    Color.clear.frame(height: AppSpacing.section)
                    rowsArea
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.label)
                .padding(.bottom, AppSpacing.block)
                // LS-251 Notes「INF-10」：04／05 是佇列列表／統計摘要，754pt 滿版欄（不是
                // 01/02/03 那套 560pt 置中欄），讓 Queue Row／Stat Card 橫向鋪開。
                .frame(maxWidth: horizontalSizeClass == .regular ? 754 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .appBackground()
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay {
            if showsCancelConfirm {
                Import04bCancelConfirmView(
                    uploadedCount: completedCount, remainingCount: batchRows.count - completedCount,
                    onKeepGoing: { showsCancelConfirm = false },
                    onConfirmCancel: {
                        store.cancelPendingImportItems(batchIDs)
                        showsCancelConfirm = false
                        onCancelledImport()
                    }
                )
            }
        }
        .onChange(of: processedCount) { _, _ in checkAllFinished() }
        .onChange(of: session.isFullyEnqueued) { _, _ in checkAllFinished() }
        .task { checkAllFinished() }
    }

    /// 見 `session.isFullyEnqueued` 文件註解——全部群都讀完、且目前已知的項目都到終局狀態，
    /// 才算整批完成，避免其他群還在非同步讀取時提早轉場。
    private func checkAllFinished() {
        guard session.isFullyEnqueued, uploadingOrWaitingCount == 0 else { return }
        onAllItemsFinished()
    }

    // MARK: - Nav Row

    private var navRow: some View {
        HStack {
            Button {
                showsCancelConfirm = true
            } label: {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "xmark").appIconFrame(.small)
                    Text("取消匯入").appFont(.body, weight: .semibold)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppSpacing.screenPad)
        .padding(.trailing, AppSpacing.item)
        .padding(.top, AppSpacing.label)
    }

    // MARK: - Total Progress Card

    private var totalProgressCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            HStack {
                Text("整體進度").appFont(.body, weight: .bold).foregroundStyle(Color.lsTextSecondary)
                Spacer(minLength: AppSpacing.label)
                Text("已處理 \(displayProcessedCount)/\(expectedTotal) 張")
                    .appNumericFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.lsSurface2)
                    Capsule().fill(Color.lsAccent).frame(width: proxy.size.width * progressFraction)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            Text("已完成 \(completedCount) 張・上傳中 \(uploadingOrWaitingCount) 張・失敗 \(failedCount) 張")
                .appFont(.note).foregroundStyle(Color.lsTextSecondary)
            if droppedCount > 0 {
                // merge-review R1 M2＋LS-96 池項 `a997f824`(1)：比照
                // `AlbumDetailView+Actions.skippedItemsReplyRow` 同型解法——讀不到／不支援
                // 格式／轉檔失敗的 asset 不靜默丟，這裡補一行讓使用者知道少了幾張、為什麼。
                HStack(alignment: .top, spacing: AppSpacing.label) {
                    Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text("\(droppedCount) 張沒有加入（格式不支援或讀取失敗）")
                        .appFont(.note).foregroundStyle(Color.lsTextSecondary)
                }
            }
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    // MARK: - Rows Area（重用 LS-142 `UploadQueueRowView`／`UploadQueueGrouping`）

    private var rowsArea: some View {
        let sections = UploadQueueGrouping.sections(for: batchRows)
        return VStack(alignment: .leading, spacing: AppSpacing.block) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text(section.title).appFont(.note, weight: .bold).foregroundStyle(Color.lsTextSecondary)
                    ForEach(section.rows) { row in
                        UploadQueueRowView(
                            row: row, thumbnail: store.thumbnail(for: row.id),
                            onRetry: { store.retry(row.id) }, onViewStorage: onViewStorage
                        )
                    }
                    if section.kind == .failed && failedCount > 1 && retryableFailedCount > 0 {
                        retryAllBar
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `LBxck`：`Retry All Bar`——同 `UploadQueueSheetView.retryAllButton` 既有樣式。
    private var retryAllBar: some View {
        Button {
            store.retryAllRetryable()
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                Text("重試這 \(retryableFailedCount) 張").appNumericFont(.body, weight: .bold)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .contentShape([.interaction, .accessibility], Rectangle())
        }
        .foregroundStyle(Color.lsTextPrimary)
        .background(Color.lsAccentSoft, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            Button {
                onLeaveInBackground()
            } label: {
                // LS-251 Notes AX3（Fgezb）：純文字 Dismiss Button 在放大字級下改固定寬度
                // 置中換行，避免橫向溢出。
                Text("在背景繼續，關閉視窗")
                    .appFont(.body, weight: .medium)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.item)
            .padding(.horizontal, AppSpacing.screenPad)
        }
        .background(Color.lsSurface)
    }
}

/// 04b 取消整批確認（`design/littlesprout.pen` `nMVqp`／AX3 `Rfl9n`；LS-251 Notes「畫面級
/// 屬性」04b 列：「標題 自訂（系統 alert 樣式仿製，非 navigationTitle）」「深色 未另畫（系統
/// alert 配色的直接延伸）」「iPad 未另畫（系統風格置中對話框與畫面寬度無關）」）。
///
/// **實作取捨（PR body／handoff 記錄）**：稿面用手繪的 Scrim＋置中 Alert Card 模擬「系統
/// alert 樣式」（Pencil 無法真的渲染 UIKit alert，只能手畫近似版）；深色／iPad 兩列的豁免
/// 理由字面就是「系統風格」——這裡改用「本畫面自畫的置中卡片」（`.overlay` 疊在 04 之上，
/// 不是 `UIAlertController`／SwiftUI `.alert()`）而非系統原生 alert，因為稿面的兩顆按鈕
/// 各自沿用 `cmp/Button Secondary`／`cmp/Button Text` 元件樣式（「繼續匯入」是實心藥丸鈕、
/// 「取消匯入」是純文字紅字鈕），系統原生 `.alert()` 的按鈕永遠是純文字列、無法重現這個
/// 視覺區分（「安全動作看起來像動作，破壞性動作只是文字連結」，同品牌其餘破壞性確認的既有
/// 語彙）。深色走 token 顏色自動切換、iPad 維持同一份置中卡片版面（不因寬度改變），與稿面
/// 豁免理由的精神一致，只是機制不同——記入 handoff「與稿差異」，非稿面缺項。
struct Import04bCancelConfirmView: View {
    let uploadedCount: Int
    let remainingCount: Int
    let onKeepGoing: () -> Void
    let onConfirmCancel: () -> Void

    var body: some View {
        ZStack {
            Color.lsPaperShadow.opacity(0.45).ignoresSafeArea()
                .onTapGesture(perform: onKeepGoing)
            alertCard
        }
    }

    private var alertCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                Text("要取消整批匯入嗎？").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                Text("已上傳的 \(uploadedCount) 張會保留，其餘 \(remainingCount) 張不會匯入。")
                    .appFont(.body).foregroundStyle(Color.lsTextSecondary)
            }
            VStack(spacing: AppSpacing.label) {
                Button(action: onKeepGoing) {
                    Text("繼續匯入").appFont(.body, weight: .bold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .foregroundStyle(Color.lsTextPrimary)
                .background(Color.lsAccentSoft, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                )
                Button(action: onConfirmCancel) {
                    Text("取消匯入").appFont(.body, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .foregroundStyle(Color.lsDanger)
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(width: 305)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview("進度") {
    let fixture = ImportPreviewFixture.makeBatch()
    Import04ProgressView(
        session: fixture.session, store: fixture.store,
        onLeaveInBackground: {}, onAllItemsFinished: {}, onCancelledImport: {}
    )
}

#Preview("取消確認") {
    Import04bCancelConfirmView(uploadedCount: 34, remainingCount: 94, onKeepGoing: {}, onConfirmCancel: {})
}

/// preview／harness 共用：`ImportBatchSession` 的 `entryIDs` 跟 `UploadQueueStore` 種子項目
/// 的 id 必須一致（04／05 都靠 `session.entryIDSet` 過濾 `store.rows`），這裡建一份兩者對得
/// 上的固定樣本，供本檔與 `Import05SummaryView.swift` 的 `#Preview`／harness 共用。
@MainActor
enum ImportPreviewFixture {
    static func makeBatch(
        completed: Int = 2, uploading: Int = 1, waiting: Int = 1,
        failed: [UploadFailureReason] = [.network, .quota]
    ) -> (session: ImportBatchSession, store: UploadQueueStore) {
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: PreviewMediaUploadService())
        let total = completed + uploading + waiting + failed.count
        let session = ImportBatchSession(expectedAssetCount: total, nonSkippedGroupCount: 1)
        func upload() -> PendingUpload {
            PendingUpload(
                kind: .photo(data: Data(), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        }
        var seeds: [UploadQueueStore.PreviewSeed] = []
        let now = Date()
        for index in 0..<completed {
            let item = upload()
            session.append(item.id)
            seeds.append(.init(item, enqueuedAt: now.addingTimeInterval(Double(-index) * 60), state: .completed))
        }
        for index in 0..<uploading {
            let item = upload()
            session.append(item.id)
            seeds.append(
                .init(item, enqueuedAt: now.addingTimeInterval(Double(-index) * 60), state: .uploading(progress: 0.4))
            )
        }
        for index in 0..<waiting {
            let item = upload()
            session.append(item.id)
            seeds.append(.init(item, enqueuedAt: now.addingTimeInterval(Double(-index) * 60), state: .waiting))
        }
        for (index, reason) in failed.enumerated() {
            let item = upload()
            session.append(item.id)
            seeds.append(
                .init(item, enqueuedAt: now.addingTimeInterval(Double(-index) * 60), state: .failed(reason))
            )
        }
        store.seedForPreview(seeds)
        session.markGroupResolved()
        return (session, store)
    }
}
#endif
