import SwiftUI

/// 03 記錄列表（LS-313，`design/littlesprout.pen` Notes `h5BNyi`→`IUdB6`〔亮〕／`xAacW`〔暗〕；
/// 抄值段 `ABhaR`）。取代 LS-312 的 `GrowthRecordsListPlaceholderView` 空殼——年份郵戳分組、
/// 滑動編輯／刪除、點一列開列操作表（`GrowthRecordActionsSheet`，非手勢替代路徑，Notes
/// `z1QNs`／M-12）。R2 merge-review i1（`a887f39`）之前 iPad（06）沒有這個入口，只靠
/// `GrowthHistorySection` 純顯示；現在 `ChildGrowthDetailView.actionsCompact`（iPhone）與
/// `regularLayout`（iPad「查看全部紀錄」連結）都會推這支畫面。
///
/// **不用 `cmp/Growth Record Row` 共用元件**（同 `GrowthHistorySection` 文件註解的既有
/// 決策）：06 的 `GrowthHistoryRow`（該檔 `private`）與這裡各自實作、手動同步——Notes 原文
/// 「`cmp/Growth Record Row` 尚未正式元件化，兩處手動同步」，YAGNI：等真的需要共用時再抽，
/// 現在抽只會抽錯形狀。
///
/// **同一份 `records`，不分頁**（`GrowthStore.fetchLimit` 文件註解）：讀 `growthStore.records`
/// （01／02 已載入的同一份），不另外呼叫 `p_before`／`p_before_id` 游標分頁——MVP 資料量遠低於
/// 200 筆上限，加分頁 UI 是驗收條件沒有要求的猜測性複雜度。
///
/// **年份郵戳＋記錄列用一維陣列模擬**（不是 `List` 的原生 `Section`）：原生 `Section` header
/// 在 `.plain` 樣式下帶有系統預設的大寫／間距樣式，跟 Notes `cmp/Day Divider` 的膠囊徽章視覺
/// 衝突，改把年份郵戳當成清單裡的一個普通列（`RowItem.yearDivider`），完全自己畫，不需要對抗
/// 系統預設樣式。
///
/// 畫面級屬性（Notes `mfafV`→`fkEE7`）：隱藏 Tab Bar ✗（一般 push）；標題系統 large；釘底
/// 動作帶無；失敗文案鍵 LS022／LS051／LS052／LS053（本畫面讀既有 `growthStore.records`、不
/// 另外呼叫 `list_growth_records`，這幾碼實際只會在 01 的 `loadState`／02／03 的寫入操作中
/// 出現——這裡列出是沿 Notes 逐字抄列，不代表這支畫面自己會產生這些錯誤態）；深色見 `xAacW`
/// （token 全自動反轉，未另畫分支）；AX3 特例見 Notes `ABhaR`：滑動揭露態上下堆疊、
/// Edit/Delete width 改 `fill_container`——本票改用系統原生 `.swipeActions`（見下），系統本身
/// 已經處理 AX3 下的揭露態版面，不需要手動實作這個分支（見型別文件註解「非手勢替代路徑」段）。
struct GrowthRecordsListView: View {
    let growthStore: GrowthStore
    let childName: String
    /// LS-313：「這筆是不是我的」判斷依據——nil 視為不是任何一筆的作者。
    let currentUserID: UUID?
    /// LS-313：owner 可以刪除（不能編輯）任何一筆，同「owner／作者權限沿 LS-57」。
    let isFamilyOwner: Bool

    @State private var editingRecord: GrowthRecord?
    @State private var deletingRecord: GrowthRecord?
    @State private var actionsRecord: GrowthRecord?

    enum RowItem: Identifiable {
        case yearDivider(Int)
        case record(GrowthRecord)

        var id: String {
            switch self {
            case .yearDivider(let year): "year-\(year)"
            case .record(let record): record.id.uuidString
            }
        }
    }

    /// R1 merge-review M2：不用 `GrowthCurve.historyRecords`（整筆同日去重）——03 是「管理」
    /// 這些記錄的地方，同一天先存身高、再存體重是兩筆不同記錄，都要能各自被看到、編輯、刪除，
    /// 不能被同日去重藏起來。全列 `growthStore.records`，以記錄 `id` 為鍵（`RowItem.id`）；
    /// 排序邏輯抽成 `GrowthCurve.allRecordsNewestFirst`（R2 merge-review R2-m1，該函式文件
    /// 註解有完整理由），這裡只轉呼叫，年份變化時插入一個郵戳列。
    ///
    /// LS-335（LS-313 R3-m1）：抽成 `static func rowItems(from:)`，讓 `GrowthCurveTests` 直接對
    /// 「列」做行為測試——原本的原始碼文字守衛可以被繞過（寫成
    /// `historyRecords(allRecordsNewestFirst(...))` 仍綠），不改行為的重構反而會讓它轉紅。
    private var rowItems: [RowItem] { Self.rowItems(from: growthStore.records) }

    static func rowItems(from records: [GrowthRecord]) -> [RowItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var items: [RowItem] = []
        var lastYear: Int?
        for record in GrowthCurve.allRecordsNewestFirst(records) {
            let year = calendar.component(.year, from: record.measuredOn)
            if year != lastYear {
                items.append(.yearDivider(year))
                lastYear = year
            }
            items.append(.record(record))
        }
        return items
    }

    private func canEdit(_ record: GrowthRecord) -> Bool {
        guard let currentUserID, let authorID = record.authorID else { return false }
        return authorID == currentUserID
    }

    private func canDelete(_ record: GrowthRecord) -> Bool {
        canEdit(record) || isFamilyOwner
    }

    var body: some View {
        Group {
            if growthStore.records.isEmpty {
                if case .failure = growthStore.loadState {
                    failureState
                } else {
                    emptyState
                }
            } else {
                list
            }
        }
        .navigationTitle("成長紀錄")
        .navigationBarTitleDisplayMode(.large)
        .appBackground()
        .sheet(item: $editingRecord) { record in
            GrowthMeasurementFormView(growthStore: growthStore, editingRecord: record)
        }
        .sheet(item: $deletingRecord) { record in
            GrowthRecordDeleteConfirmationSheet(growthStore: growthStore, record: record)
        }
        .sheet(item: $actionsRecord) { record in
            GrowthRecordActionsSheet(
                record: record,
                onEdit: canEdit(record) ? { editingRecord = record } : nil,
                onDelete: canDelete(record) ? { deletingRecord = record } : nil
            )
        }
    }

    /// R1 merge-review M3：Notes `IUdB6` Body 對整個列表區塊有左右 `$screen-pad`——原本
    /// `listRowInsets` leading／trailing 皆 0，副標與卡片貼著螢幕邊緣。
    private var list: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 0, leading: AppSpacing.screenPad, bottom: 0, trailing: AppSpacing.screenPad
                ))
            ForEach(rowItems) { item in
                row(for: item)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: AppSpacing.tight, leading: AppSpacing.screenPad,
                        bottom: AppSpacing.tight, trailing: AppSpacing.screenPad
                    ))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Notes `IUdB6`「Header」的「Title」節點是 Pencil 對系統 large navigationTitle 的稿面
    /// 示意（同 01/04 等「標題 系統 large」畫面的既有慣例——Notes 逐字寫「標題 系統 large」，
    /// 不是要求另外用 body content 畫一次），這裡只畫「Subtitle」；`.navigationTitle("成長
    /// 紀錄")`（見 `body`）已經是那顆系統標題。R1 模擬器實測抓到的真實 bug：一開始兩者都畫，
    /// 畫面上「成長紀錄」重複印兩次（系統大標題＋這裡的 body Text）。
    private var header: some View {
        // Notes `Text("\(count)")` 對 `Int` 插值會套用 Text 的預設數字 FormatStyle（含千分
        // 位）——`String(...)` 先轉成字串插值，避開這條數字格式化路徑（同 `yearDivider(_:)`
        // 的既有理由）。
        Text("\(childName) · 共 \(String(growthStore.records.count)) 筆紀錄。左滑或點一列都可以編輯、刪除。")
            .appFont(.note)
            .foregroundStyle(Color.lsTextSecondary)
            .padding(.bottom, AppSpacing.item)
    }

    @ViewBuilder
    private func row(for item: RowItem) -> some View {
        switch item {
        case .yearDivider(let year):
            yearDivider(year)
        case .record(let record):
            recordRow(record)
        }
    }

    /// Notes 沿用 `cmp/Day Divider` 年份郵戳（同 `GrowthHistorySection.GrowthYearDivider`，
    /// 兩處各自實作，見型別文件註解）。R1 模擬器實測抓到的真實 bug：`Text("\(year)年")`
    /// 對 `Int` 插值會套用 `Text` 的預設數字 `FormatStyle`（含千分位），2026 顯示成
    /// 「2,026年」——先 `String(year)` 轉成字串插值，避開這條數字格式化路徑。
    private func yearDivider(_ year: Int) -> some View {
        Text("\(String(year))年")
            .appFont(.meta, weight: .bold)
            .foregroundStyle(Color.lsTextSecondary)
            .padding(.horizontal, AppSpacing.group)
            .padding(.vertical, AppSpacing.tight)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsBorder, lineWidth: 1)
            )
    }

    /// 兩個動作皆不可用（既非作者也非 owner，例如 viewer）時整列維持純顯示——不包 `Button`、
    /// 不掛 `.swipeActions`（品牌硬約束不 disable，但這裡不是「disable 一個動作」，是「這個
    /// 動作對這個角色從未存在過」，同 `identityHeader()` 的 `editDestination` 為 nil 時不畫
    /// 「編輯」鈕的既有精神）。
    @ViewBuilder
    private func recordRow(_ record: GrowthRecord) -> some View {
        let editable = canEdit(record)
        let deletable = canDelete(record)
        Group {
            if editable || deletable {
                Button {
                    actionsRecord = record
                } label: {
                    GrowthRecordCard(record: record)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if deletable {
                        Button(role: .destructive) { deletingRecord = record } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                    if editable {
                        Button { editingRecord = record } label: {
                            Label("編輯", systemImage: "pencil")
                        }
                        .tint(Color.lsAccent)
                    }
                }
            } else {
                GrowthRecordCard(record: record)
            }
        }
    }

    /// 沒有紀錄（例如全部軟刪之後回到這頁，或還沒新增過任何一筆就先點了「查看全部紀錄」）——
    /// Notes 沒有為 03 另畫空狀態板，沿用 04 空狀態的既有文案（`GrowthEmptyStateCopy`），不
    /// 另外發明新文案；不重畫 04 的曲線骨架卡（那是概覽頁的角色，這裡是列表頁，純文字置中
    /// 即可，工程判斷，非逐字規格）。
    private var emptyState: some View {
        VStack(spacing: AppSpacing.item) {
            Image(systemName: "list.bullet.rectangle")
                .appIconFrame(.large)
                .foregroundStyle(Color.lsTextSecondary)
            Text(GrowthEmptyStateCopy.title)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(GrowthEmptyStateCopy.body(childName: childName))
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// R1 merge-review m4：01 讀取失敗時（例如離線）`growthStore.records` 也是空的，使用者仍
    /// 可能已經按過「查看全部紀錄」進到這裡——不能顯示上面 `emptyState` 那句「還沒有紀錄」
    /// （那是「這個孩子真的還沒量過」的語意，跟「讀取失敗」是兩件不同的事，同 LS-312 M2
    /// 既有語彙：`ChildGrowthDetailView.failureBanner` 錯誤文案＋「重新載入」，這裡沒有骨架卡
    /// 可以疊，改整頁置中呈現）。
    private var failureState: some View {
        VStack(spacing: AppSpacing.item) {
            Image(systemName: "exclamationmark.circle")
                .appIconFrame(.large)
                .foregroundStyle(Color.lsTextSecondary)
            if case .failure(let error) = growthStore.loadState {
                Text(error.userFacingMessage)
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await growthStore.refresh() }
            } label: {
                Text("重新載入")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(minHeight: 48)
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 單筆記錄卡（Notes `IUdB6`：日期＋逐項「有值」的量測＋備註摘要）——同
/// `GrowthHistorySection.GrowthHistoryRow` 的角色分工，兩處各自實作（見型別文件註解）。
private struct GrowthRecordCard: View {
    let record: GrowthRecord

    private var presentMetrics: [(metric: GrowthMetric, value: Double)] {
        GrowthMetric.allCases.compactMap { metric in
            metric.value(in: record).map { (metric, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(record.measuredOnHistoryLabel)
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
            ForEach(presentMetrics, id: \.metric) { entry in
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: entry.metric.systemImage)
                        .appIconFrame(.small)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text(entry.metric.label)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text("\(entry.metric.formattedValue(entry.value)) \(entry.metric.unit)")
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextPrimary)
                }
            }
            if let note = record.note, !note.isEmpty {
                Text(note)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.group)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }
}

#if DEBUG
#Preview("亮") {
    NavigationStack {
        GrowthRecordsListView(
            growthStore: .previewSeededWithDemoRecords(), childName: "陳小安",
            currentUserID: GrowthStore.previewAuthorID, isFamilyOwner: true
        )
    }
}

#Preview("空") {
    NavigationStack {
        GrowthRecordsListView(
            growthStore: .preview(), childName: "陳小軒", currentUserID: nil, isFamilyOwner: false
        )
    }
}
#endif
