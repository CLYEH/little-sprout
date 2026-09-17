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
                    // 票文範圍 3：「重試失敗項（只重跑失敗項）」——`retryAllRetryable()` 本身
                    // 就只翻可重試的失敗列回 `.waiting`，不動已完成／不可重試（LS002）的項目。
                    Button {
                        store.retryAllRetryable()
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
    Import05SummaryView(session: fixture.session, store: fixture.store, onDone: {})
}

#Preview("全成功") {
    let fixture = ImportPreviewFixture.makeBatch(completed: 7, uploading: 0, waiting: 0, failed: [])
    Import05SummaryView(session: fixture.session, store: fixture.store, onDone: {})
}
#endif
