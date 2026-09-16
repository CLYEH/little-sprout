import SwiftUI

/// 寶貝詳情・成長區塊（LS-312，`design/littlesprout.pen` `jp6ka`〔01 iPhone〕／`DHwk2`〔04
/// 空狀態，`growthStore.isEmpty` 時自動切換〕／`pjrd7`〔06 iPad，`horizontalSizeClass ==
/// .regular` 時切換，同 `ChildrenManagementView.compactLayout`/`regularLayout` 既有分流
/// 慣例〕）。
///
/// 畫面級屬性（Notes `mfafV`→`PgHMe`／`tMMVT`／`H58CA`，逐條落地）：隱藏 Tab Bar ✗（一般
/// push，Tab Bar 維持顯示——本視圖不呼叫 `.toolbar(.hidden, for: .tabBar)`）；標題系統
/// large（`.navigationTitle(childName)`，不覆寫 display mode）；釘底動作帶無；深色靠 token
/// 全自動反轉，紙卡（`GrowthChartCardView`）刻意不隨 theme 變色；AX3 靠
/// `GrowthSegmentedControl`／`GrowthChartCardView` 各自讀 `dynamicTypeSize` 切換直式堆疊與
/// X 軸刻度密度；iPad 見 `regularLayout`。
///
/// **導覽入口尚未接上**（PR「未完成」欄）：`ChildrenManagementView` 的寶貝列目前仍直接導向
/// `EditChildView`（09b）——本票範圍（LS-312「範圍」段 1–6）未列「修改 09 導覽」，這支畫面
/// 目前只能透過 `TapTargetGateHarness`／`#Preview` 建構測試。導覽接線留給後續票（見 handoff
/// 風險欄）。
struct ChildGrowthDetailView: View {
    let growthStore: GrowthStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedMetric: GrowthMetric = .height
    @State private var showsAddMeasurement = false

    /// Notes `LiJgw`（04 AX3）：「Empty Message topMargin 110、plotH 340 避免文字擠壓」——
    /// AX3 空狀態文案（含孩子名字，最長可能三行）需要比一般字級更高的繪圖區，否則會跟
    /// 「月齡」軸名擠在一起（R1 模擬器實測抓到的視覺缺陷）。populated 態不受影響（真的有
    /// 資料時骨架版不會渲染）。
    private var chartPlotHeight: CGFloat {
        guard horizontalSizeClass != .regular else { return 320 }
        return dynamicTypeSize >= .accessibility3 ? 340 : 220
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .navigationTitle(growthStore.childName)
        .task {
            // `loadState == .idle` 才真的呼叫——`#Preview`／`TapTargetGateHarness` 用
            // `seedForPreview` 種好資料後 `loadState` 已是 `.success`，這裡不能無條件呼叫
            // `refresh()`（假 client 固定回傳 `[]`，會把種好的示範資料覆蓋成空狀態）。
            guard growthStore.loadState == .idle else { return }
            await growthStore.refresh()
        }
        .sheet(isPresented: $showsAddMeasurement) {
            GrowthAddMeasurementPlaceholderView()
        }
    }

    // MARK: - Compact (iPhone) — 01／04

    private var compactLayout: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                identityHeader
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text("最新紀錄")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                    latestValuesRow
                }
                GrowthChartCardView(
                    titleFont: .body, metric: $selectedMetric,
                    points: growthStore.curvePoints(for: selectedMetric),
                    isEmptyState: growthStore.isEmpty, childName: growthStore.childName,
                    plotHeight: chartPlotHeight
                )
                actionsCompact
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.item)
        }
        .appBackground()
    }

    private var actionsCompact: some View {
        VStack(spacing: AppSpacing.group) {
            PrimaryButton(icon: "plus", title: "新增量測") {
                showsAddMeasurement = true
            }
            NavigationLink {
                GrowthRecordsListPlaceholderView()
            } label: {
                Text("查看全部紀錄")
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Regular (iPad) — 06

    /// 只負責 Content Pane 本身的內容——左側 Nav Sidebar（時間軸／相簿／寶貝／設定）是
    /// `RootView.SectionSplitView` 既有的 app 層 iPad 殼（見該檔），不是這張票的範圍，這裡
    /// 不重畫一份。
    private var regularLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                identityHeader
                GrowthChartCardView(
                    titleFont: .lead, metric: $selectedMetric,
                    points: growthStore.curvePoints(for: selectedMetric),
                    isEmptyState: growthStore.isEmpty, childName: growthStore.childName,
                    plotHeight: chartPlotHeight
                )
                VStack(alignment: .leading, spacing: AppSpacing.item) {
                    Text("最新紀錄")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                    latestValuesRow
                }
                PrimaryButton(icon: "plus", title: "新增量測") {
                    showsAddMeasurement = true
                }
                if !growthStore.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.item) {
                        Text("歷史紀錄")
                            .appFont(.body)
                            .foregroundStyle(Color.lsTextPrimary)
                        GrowthHistorySection(records: growthStore.records)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.screenPadLarge)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
        .appBackground()
    }

    // MARK: - 共用

    private var identityHeader: some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(name: growthStore.childName, size: 64)
            VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(growthStore.childName)
                    .appFont(.display, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                Text(BirthdayFormat.ageDescription(birthday: growthStore.childBirthday))
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
    }

    private var latestValuesRow: some View {
        HStack(spacing: AppSpacing.group) {
            ForEach(GrowthMetric.allCases) { metric in
                GrowthLatestValueCard(metric: metric, latest: growthStore.latestValue(for: metric))
            }
        }
    }
}

#Preview("01 有資料") {
    NavigationStack {
        ChildGrowthDetailView(growthStore: .previewSeededWithDemoRecords())
    }
}

#Preview("04 空狀態") {
    NavigationStack {
        ChildGrowthDetailView(growthStore: .preview(childName: "陳小軒"))
    }
}
