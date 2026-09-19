import SwiftUI

/// 完成摘要頁（`design/littlesprout.pen` Import `05 完成摘要 (iPhone)` `L6zy2`／深色
/// `qGUTt`／AX3 `CDlkK`／iPad `C09ZI`；LS-251 Notes「畫面級屬性」05 列）——`ImportBatchFlowContainer`
/// 內部轉場的終點，`Import04ProgressView` 全部批次項目到終局狀態後自動轉進來（LS-251 Notes
/// 「狀態機」④）。同 `Import04ProgressView` 檔頭理由：全螢幕蓋版本身已蓋掉 Tab Bar，不需要
/// `QA-GATE` 標記；自訂 Nav Row＋Body 內大標題，不用系統 `.navigationTitle`。
///
/// 主鈕「回到時間軸」（C3a／裁決點③：兩種預設相簿情境下這句文案都成立，不因入口相簿預設值
/// 而分支，見 LS-251 Notes「裁決點清單」③）——`onDone()` 由呼叫端關掉整條批次匯入流程。
struct Import05SummaryView: View {
    let session: ImportBatchSession
    let store: UploadQueueStore
    /// LS-319：批次匯入「指定寶貝」標記追蹤器——「N 張寶貝標記未完成」與「重試標記」讀寫這個
    /// 物件，範圍只看跟這個批次（`session.entryIDSet`）有交集的群，見 `MediaChildrenMarkingTracker
    /// .failedMarkingMediaCount(in:)` 文件註解。
    let marker: MediaChildrenMarkingTracker
    var onViewStorage: () -> Void = {}
    let onDone: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var batchRows: [UploadQueueRow] { store.rows(in: session.entryIDSet) }
    private var completedCount: Int { batchRows.count { if case .completed = $0.state { true } else { false } } }
    private var failedRows: [UploadQueueRow] { batchRows.filter { if case .failed = $0.state { true } else { false } } }
    private var retryableFailedCount: Int {
        failedRows.count { row in
            if case .failed(let reason) = row.state { return reason.isRetryable }
            return false
        }
    }
    /// LS-319：只算跟這個批次有交集的標記失敗群——上傳失敗（`failedRows`）與標記失敗是兩件
    /// 不同的事（票文範圍 2：上傳失敗不計入標記失敗），這裡刻意不共用 `failedRows` 的計算。
    /// 統計列用這個（不分是否可重試，照片確實沒有標記是事實）。
    private var markingFailedCount: Int { marker.failedMarkingMediaCount(in: session.entryIDSet) }
    /// LS-319 R2（merge-review R1 m2）：「重試標記」鈕只在還有**可重試**的失敗群時才顯示——
    /// `LS044`（寶貝已軟刪）原樣重送永遠不會成功，沿既有「重試失敗項排除 LS002」的 tier 慣例。
    private var retryableMarkingFailedCount: Int { marker.retryableFailedMarkingCount(in: session.entryIDSet) }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Color.clear.frame(height: AppSpacing.block)
                    statsCard
                    if !failedRows.isEmpty {
                        Color.clear.frame(height: AppSpacing.section)
                        failedSection
                    }
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.label)
                .padding(.bottom, AppSpacing.block)
                // LS-251 Notes「INF-10」：同 `Import04ProgressView`，754pt 滿版欄。
                .frame(maxWidth: horizontalSizeClass == .regular ? 754 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .appBackground()
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var navRow: some View {
        HStack {
            Button(action: onDone) {
                Text("完成").appFont(.body, weight: .semibold)
                    .frame(minWidth: 44, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppSpacing.screenPad)
        .padding(.trailing, AppSpacing.item)
        .padding(.top, AppSpacing.label)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text("匯入完成").appFont(.display, weight: .bold).foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("共 \(session.nonSkippedGroupCount) 個日期群")
                .appFont(.body).foregroundStyle(Color.lsTextSecondary)
        }
    }

    // MARK: - Stats Card

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "checkmark.circle.fill").appIconFrame(.large).foregroundStyle(Color.lsSuccess)
                VStack(alignment: .leading, spacing: 0) {
                    // 05 R2（LS-251 Notes「字級」段）：成功統計數字改用 $fs-display（與失敗
                    // 統計不對稱設計，主角數字要認得出主角）。
                    Text("\(completedCount) 張").appNumericFont(.display, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                    Text("已成功匯入").appFont(.note).foregroundStyle(Color.lsTextSecondary)
                }
            }
            if !failedRows.isEmpty {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small)
                        .foregroundStyle(Color.lsDanger)
                    Text("\(failedRows.count) 張沒有成功")
                        .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                }
            }
            if session.droppedCount > 0 {
                // merge-review R1 M2＋LS-96 池項 `a997f824`(1)：同 `Import04ProgressView`——
                // 讀不到／不支援格式／轉檔失敗的 asset 從未進佇列，不屬於 `failedRows`，這裡
                // 另起一行講清楚，數字契約「成功＋沒有成功＋沒有加入＝開始匯入時看到的總數」
                // 才成立（04→05 一路沿用同一個 `session.droppedCount`）。
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text("\(session.droppedCount) 張沒有加入（格式不支援或讀取失敗）")
                        .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                }
            }
            if markingFailedCount > 0 {
                // LS-319：照片本身已上傳成功，只是寶貝標記沒有落地——沿用「N 張沒有成功」那一
                // 列的元件語彙（exclamationmark.circle.fill＋lsDanger），這裡另起一行不跟
                // `failedRows` 混在一起，理由同上（上傳失敗與標記失敗是兩件不同的事）。稿面
                // （LS-251 05 板）沒有這一列，沿用既有「失敗項＋重試」元件語彙頂上，實作細節見
                // handoff 畫面級屬性段，交 orchestrator 判斷是否需要補設計。
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small)
                        .foregroundStyle(Color.lsDanger)
                    Text("\(markingFailedCount) 張寶貝標記未完成")
                        .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                }
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    // MARK: - Failed Section（重用 LS-142 `UploadQueueRowView`）

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            Text("這 \(failedRows.count) 張沒有成功")
                .appFont(.note, weight: .bold).foregroundStyle(Color.lsTextSecondary)
            ForEach(failedRows) { row in
                UploadQueueRowView(
                    row: row, thumbnail: store.thumbnail(for: row.id),
                    onRetry: { store.retry(row.id) }, onViewStorage: onViewStorage
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            VStack(spacing: AppSpacing.label) {
                Button(action: onDone) {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "clock").appIconFrame(.medium)
                        Text("回到時間軸").appFont(.body, weight: .bold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                }
                .foregroundStyle(Color.lsOnAccent)
                .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                if retryableFailedCount > 0 {
                    // 票文範圍 3：「重試失敗項（只重跑失敗項）」——`retryRetryable(in:)` 只翻
                    // 這個批次自己範圍內可重試的失敗列回 `.waiting`，不動已完成／不可重試
                    // （LS002）的項目，也不動共用佇列裡其他批次／單張即傳的失敗列（merge-review
                    // R1 m1）。
                    Button {
                        store.retryRetryable(in: session.entryIDSet)
                    } label: {
                        HStack(spacing: AppSpacing.label) {
                            Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                            Text("重試失敗項（\(retryableFailedCount)）").appNumericFont(.body, weight: .bold)
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
                if retryableMarkingFailedCount > 0 {
                    // LS-319（票文範圍 2）：「重試標記」只重送標記失敗的群，不重新上傳（上傳
                    // 早就成功了，見 `MediaChildrenMarkingTracker.retryFailedMarking(in:)` 文件
                    // 註解）——沿用「重試失敗項（N）」按鈕的元件語彙（同背景／邊框／字級），
                    // 只換文案與觸發對象，同上一段理由，交 orchestrator 判斷是否需要補設計。
                    // m2（merge-review R1）：只在還有可重試的失敗群時才顯示，`LS044` 排除。
                    Button {
                        marker.retryFailedMarking(in: session.entryIDSet)
                    } label: {
                        HStack(spacing: AppSpacing.label) {
                            Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                            Text("重試標記（\(retryableMarkingFailedCount)）").appNumericFont(.body, weight: .bold)
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
            }
            .padding(.vertical, AppSpacing.item)
            .padding(.horizontal, AppSpacing.screenPad)
        }
        .background(Color.lsSurface)
    }
}

#if DEBUG
#Preview("有失敗") {
    let fixture = ImportPreviewFixture.makeBatch(completed: 5, uploading: 0, waiting: 0, failed: [.network, .quota])
    Import05SummaryView(
        session: fixture.session, store: fixture.store, marker: AlbumsStore.preview().mediaChildrenMarker, onDone: {}
    )
}

#Preview("全成功") {
    let fixture = ImportPreviewFixture.makeBatch(completed: 7, uploading: 0, waiting: 0, failed: [])
    Import05SummaryView(
        session: fixture.session, store: fixture.store, marker: AlbumsStore.preview().mediaChildrenMarker, onDone: {}
    )
}
#endif
