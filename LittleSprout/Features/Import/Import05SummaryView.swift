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
    /// LS-319：批次匯入「指定寶貝」標記追蹤器——「其中 N 張的寶貝沒有指定成功」與「補上寶貝」
    /// （LS-373）讀寫這個物件，範圍只看跟這個批次（`session.entryIDSet`）有交集的群，見 `MediaChildrenMarkingTracker
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
    /// LS-319 R2（merge-review R1 m2）：「補上寶貝」鈕只在還有**可重試**的失敗群時才顯示——
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
                    if let markingSection = content.markingSection {
                        // D3／D4（`IpMe2`／05b `J9ksa`）：Failed Section 之後（沒有上傳失敗時直接
                        // 接統計卡）再一個 44 斷點。
                        Color.clear.frame(height: AppSpacing.section)
                        markingSectionView(markingSection)
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

    /// LS-373：統計列與寶貝段落的數字／文案一律取自純函式 `Import05SummaryContent`（數字契約與
    /// 逐字文案在那裡鎖住並有單元測試），這裡只負責排版。
    private var content: Import05SummaryContent {
        Import05SummaryContent(
            completedCount: completedCount, failedCount: failedRows.count, droppedCount: session.droppedCount,
            markingFailedCount: markingFailedCount, retryableMarkingFailedCount: retryableMarkingFailedCount
        )
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            ForEach(content.statRows, id: \.self) { row in
                statRow(row)
            }
        }
        .padding(AppSpacing.insetCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statRow(_ row: Import05SummaryContent.StatRow) -> some View {
        switch row {
        case .succeeded(let count, let unassignedBabyCount):
            // LS-349 Success Group（`l2nLL`）：成功統計＋寶貝未指定子列，gap $sp-label。
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "checkmark.circle.fill").appIconFrame(.large).foregroundStyle(Color.lsSuccess)
                    VStack(alignment: .leading, spacing: 0) {
                        // 05 R2（LS-251 Notes「字級」段）：成功統計數字改用 $fs-display（與失敗
                        // 統計不對稱設計，主角數字要認得出主角）。
                        Text("\(count) 張").appNumericFont(.display, weight: .bold)
                            .foregroundStyle(Color.lsTextPrimary)
                        Text("已成功匯入").appFont(.note).foregroundStyle(Color.lsTextSecondary)
                    }
                }
                if unassignedBabyCount > 0 {
                    // D1（`D45LkN`）：成功之中寶貝沒有指定成功的子集——左縮對齊「已成功匯入」字首
                    // （用與成功 icon 同一個 `appIconFrame(.large)` 的透明占位，Dynamic Type 放大
                    // 時仍對齊）；icon `figure.child`（與相簿詳情孩子 Pill 同符號）$text-primary，
                    // 文字 $text-secondary。
                    HStack(alignment: .top, spacing: AppSpacing.label) {
                        Color.clear.appIconFrame(.large).frame(height: 0)
                        iconLineBox("figure.child", color: Color.lsTextPrimary)
                        Text(Import05SummaryContent.unassignedBabyLine(count: unassignedBabyCount))
                            .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .failed(let count):
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small)
                    .foregroundStyle(Color.lsDanger)
                Text("\(count) 張沒有成功")
                    .appNumericFont(.note).foregroundStyle(Color.lsTextSecondary)
            }
        case .dropped(let count):
            // D2（`LbgZW`）：讀不到／不支援格式／轉檔失敗的 asset 從未進佇列（merge-review R1 M2
            // ＋LS-96 池項 `a997f824`(1)）；icon `minus.circle`（05 家族只代表「沒有加入」），
            // 文案拆兩行，icon 對首行。
            HStack(alignment: .top, spacing: AppSpacing.label) {
                iconLineBox("minus.circle", color: Color.lsTextSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(count) 張沒有加入").appNumericFont(.note)
                    Text("格式不支援或讀取失敗").appFont(.note)
                }
                .foregroundStyle(Color.lsTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 稿面 Icon Line Box（Notes `T5gSe`：高＝$fs-note 單行行高、icon 置中）——用同字級的隱藏
    /// 單行字撐出行高，Dynamic Type 放大時 icon 仍對齊首行中線。
    private func iconLineBox(_ systemName: String, color: Color) -> some View {
        ZStack {
            Text(verbatim: "\u{00A0}").appFont(.note).hidden()
            Image(systemName: systemName).appIconFrame(.small).foregroundStyle(color)
        }
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

    // MARK: - Marking Section（LS-349 D3／D4）

    private func markingSectionView(_ section: Import05SummaryContent.MarkingSection) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            Text(section.header)
                .appNumericFont(.note, weight: .bold).foregroundStyle(Color.lsTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 一組一個 VStack、一句一個 Text（稿面全稿不用手動換行）：組內 $sp-label、組間 $sp-item。
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                ForEach(section.noteGroups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: AppSpacing.label) {
                        ForEach(group, id: \.self) { sentence in
                            Text(sentence).appNumericFont(.note).foregroundStyle(Color.lsTextPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if section.fillableCount > 0 {
                fillBabiesButton(count: section.fillableCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「補上寶貝（N）」（`I8MyXS`／05b `xnOYi`）：`cmp/Button Text`（與 Failed Section 逐列「重試」
    /// 同一元件：無底無框，icon 22＋$fs-body 600，$text-primary）——照片已經在時間軸上，這顆只補
    /// 寶貝、位階低於動作帶的「重試失敗項」，所以放在內容區段落最後、不進動作帶（Notes `soWdb`）。
    /// 只重送標記失敗且可重試的群，不重新上傳（見 `MediaChildrenMarkingTracker
    /// .retryFailedMarking(in:)` 文件註解）。
    private func fillBabiesButton(count: Int) -> some View {
        // D5（Notes `x73Dy6`／`XG9yu`）：請求進行中整顆停用、icon 位置換 ProgressView、label 改
        // 「正在補上寶貝…」，icon 與字 $text-secondary；版面不動（列與段落等結果回來才更新）。
        let isInFlight = marker.isRetryingMarking(in: session.entryIDSet)
        let presentation = Import05SummaryContent.fillBabiesButton(count: count, isInFlight: isInFlight)
        return Button {
            marker.retryFailedMarking(in: session.entryIDSet)
        } label: {
            HStack(spacing: AppSpacing.label) {
                if isInFlight {
                    ProgressView().controlSize(.small).tint(Color.lsTextSecondary).appIconFrame(.medium)
                } else {
                    Image(systemName: "arrow.clockwise").appIconFrame(.medium)
                }
                Text(presentation.title).appNumericFont(.body, weight: .semibold)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isInFlight ? Color.lsTextSecondary : Color.lsTextPrimary)
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.tight)
            .frame(minHeight: 48, alignment: .leading)
            .contentShape([.interaction, .accessibility], Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.isDisabled)
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
