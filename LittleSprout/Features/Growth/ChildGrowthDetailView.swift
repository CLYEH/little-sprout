import SwiftUI

/// 寶貝詳情・成長區塊（LS-312，`design/littlesprout.pen` `jp6ka`〔01 iPhone〕／`DHwk2`〔04
/// 空狀態，`growthStore.isEmpty` 時自動切換〕）。iPad（06，`pjrd7`）另一支 commit 補上
/// `regularLayout`——本 commit 先落地 01／04 共用的 compact 版面，`horizontalSizeClass ==
/// .regular` 暫時沿用 compact 版面（下一支 commit 換成真正的雙欄 Content Pane）。
///
/// 畫面級屬性（Notes `mfafV`→`PgHMe`／`tMMVT`，逐條落地）：隱藏 Tab Bar ✗（一般 push，
/// Tab Bar 維持顯示——本視圖不呼叫 `.toolbar(.hidden, for: .tabBar)`）；標題系統 large
/// （`.navigationTitle(childName)`，不覆寫 display mode）；釘底動作帶無；深色靠 token 全自動
/// 反轉，紙卡（`GrowthChartCardView`）刻意不隨 theme 變色；AX3 靠 `GrowthSegmentedControl`／
/// `GrowthChartCardView` 各自讀 `dynamicTypeSize` 切換直式堆疊與 X 軸刻度密度。
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
        dynamicTypeSize >= .accessibility3 ? 340 : 220
    }

    var body: some View {
        compactLayout
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
