import SwiftUI

/// 成長曲線卡（01／06 共用；`isEmptyState: true` 時渲染 04 骨架版，Notes `yHb3o`／`ZiUDD`／
/// `jrsot`）。材質規則（Notes `Fnrje`）：`$print-paper` 不掛 theme，卡內文字一律
/// `$print-ink`／`$print-ink-secondary`，深色模式下紙卡仍是淺色可讀，不隨 dark mode 反轉。
///
/// Y 軸格線改依目前選取的量測項動態算（`GrowthCurve.gridlines`）——抄值表 `wgF5u` 的
/// `[85,70,55,40]` 只是示範資料集「身高」這一項算出來的結果，體重（kg）／頭圍（cm）數值
/// 範圍完全不同，三項切換必須重新算格線，不能整段照抄那組硬值（PR「已完成」欄註記這個
/// 取捨）。
///
/// X 軸月齡用 `GeometryReader` 比例定位（Notes `ZuKEF`「真正線性月齡刻度」的精神：
/// 像素位置依真實月齡比例，不是等分類別軸）；不照抄 `colW`/`plotW` 等固定 pt 常數——
/// 那些是 Pencil 稿面單一 iPhone 尺寸下量出來的結果，`GeometryReader` 比例映射在
/// iPhone／iPad／AX3 各種寬度下都能保持「真線性」，不需要為每個尺寸各自硬寫一組常數。
struct GrowthChartCardView: View {
    let titleFont: AppFontToken
    @Binding var metric: GrowthMetric
    let points: [GrowthCurve.CurvePoint]
    let isEmptyState: Bool
    let childName: String
    var plotHeight: CGFloat = 220

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedPointIndex: Int?

    private var isCompactAxisDensity: Bool { dynamicTypeSize >= .accessibility3 }
    private var gridlineValues: [Double] { GrowthCurve.gridlines(values: points.map(\.value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            Text("成長曲線")
                .appFont(titleFont, weight: .bold)
                .foregroundStyle(Color.lsPrintInk)
            GrowthSegmentedControl(selection: $metric)
                .onChange(of: metric) { _, _ in selectedPointIndex = nil }
            plotArea
        }
        .padding(AppSpacing.item)
        .background(Color.lsPrintPaper, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsPaperEdge, lineWidth: 1)
        )
        .shadow(color: Color.lsPaperShadow, radius: 6, y: 3)
    }

    @ViewBuilder
    private var plotArea: some View {
        if isEmptyState {
            skeletonPlot
        } else {
            populatedPlot
        }
    }

    /// Notes `l08lnc`：「沒有資料點的骨架版（04）不標任何刻度數字，只留淡淡格線與軸名
    /// 『月齡』」——固定 4 條示意格線（不依真實資料算，因為根本沒有資料），置中疊 Empty
    /// Message（Notes `C8yU4O`：Lead＋Body 兩行）。
    private var skeletonPlot: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle().fill(Color.lsPaperRule).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            VStack(spacing: AppSpacing.label) {
                Text(GrowthEmptyStateCopy.title)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsPrintInk)
                Text(GrowthEmptyStateCopy.body(childName: childName))
                    .appFont(.meta)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.block)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("月齡")
                        .appFont(.meta)
                        .foregroundStyle(Color.lsPrintInkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: plotHeight)
    }

    private var populatedPlot: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                gridlines(size: geometry.size)
                if points.count >= 2 {
                    growthLine(size: geometry.size)
                }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    dataPoint(point, index: index, isLatest: index == points.count - 1, size: geometry.size)
                }
                axisLabels(size: geometry.size)
            }
        }
        .frame(height: plotHeight)
    }

    /// 單位（「cm」／「kg」）只標在最上面那條格線（Notes `WUKs7`「單位標籤置於左上角一次，
    /// 不逐條格線重複」）——直接併進那條線的文字，不另外疊一個獨立的「cm」角標：R1 模擬器
    /// 實測抓到獨立角標會跟最上面那條格線的數字疊字（兩者都貼在繪圖區左上角同一個位置）。
    private func gridlines(size: CGSize) -> some View {
        ForEach(Array(gridlineValues.enumerated()), id: \.offset) { index, value in
            let lineY = yPosition(for: value, size: size)
            let isTopmost = index == gridlineValues.count - 1
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.lsPaperRule).frame(height: 1)
                Text(isTopmost ? "\(metric.formattedValue(value)) \(metric.unit)" : metric.formattedValue(value))
                    .appFont(.note)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .offset(y: -14)
            }
            .frame(width: size.width)
            .position(x: size.width / 2, y: lineY)
        }
    }

    private func growthLine(size: CGSize) -> some View {
        Path { path in
            for (index, point) in points.enumerated() {
                let position = position(for: point, size: size)
                if index == 0 {
                    path.move(to: position)
                } else {
                    path.addLine(to: position)
                }
            }
        }
        .stroke(Color.lsPrintInk, lineWidth: 2)
    }

    private func dataPoint(_ point: GrowthCurve.CurvePoint, index: Int, isLatest: Bool, size: CGSize) -> some View {
        let position = position(for: point, size: size)
        return ZStack {
            Circle()
                .fill(isLatest ? Color.lsPrintInk : Color.lsPrintPaper)
                .overlay(Circle().strokeBorder(Color.lsPrintInk, lineWidth: 1.5))
                .frame(width: isLatest ? 12 : 8, height: isLatest ? 12 : 8)
            if selectedPointIndex == index {
                Text("\(metric.formattedValue(point.value)) \(metric.unit)")
                    .appFont(.note)
                    .foregroundStyle(Color.lsPrintInk)
                    .padding(.horizontal, AppSpacing.label)
                    .padding(.vertical, AppSpacing.tight)
                    .background(Color.lsPrintPaper, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                            .strokeBorder(Color.lsPaperEdge, lineWidth: 1)
                    )
                    .offset(y: -32)
            }
        }
        .frame(minWidth: 48, minHeight: 48)
        .contentShape(Rectangle())
        .position(position)
        .onTapGesture {
            selectedPointIndex = selectedPointIndex == index ? nil : index
        }
    }

    /// 上／下留白——避免最低／最高格線正好貼齊繪圖區邊界、跟月齡刻度或「cm」單位標籤疊字
    /// （R1 模擬器實測抓到的視覺缺陷：底部格線與月齡數字擠在同一條 y，見 commit 說明）。
    private static let topInset: CGFloat = 24
    private static let bottomInset: CGFloat = 44

    @ViewBuilder
    private func axisLabels(size: CGSize) -> some View {
        let labelIndices = Set(
            GrowthCurve.xAxisLabelIndices(pointCount: points.count, isCompactDensity: isCompactAxisDensity)
        )
        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            if labelIndices.contains(index) {
                Text("\(point.ageMonths)")
                    .appFont(.note)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .position(x: position(for: point, size: size).x, y: size.height - Self.bottomInset + 24)
            }
        }
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("月齡")
                    .appFont(.meta)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .padding(.bottom, Self.bottomInset - 12)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func yPosition(for value: Double, size: CGSize) -> CGFloat {
        let plotHeight = max(size.height - Self.topInset - Self.bottomInset, 1)
        guard let lower = gridlineValues.first, let upper = gridlineValues.last, upper > lower else {
            return Self.topInset + plotHeight / 2
        }
        let ratio = (value - lower) / (upper - lower)
        return Self.topInset + plotHeight - CGFloat(ratio) * plotHeight
    }

    private func position(for point: GrowthCurve.CurvePoint, size: CGSize) -> CGPoint {
        let ages = points.map(\.ageMonths)
        let minAge = ages.min() ?? point.ageMonths
        let maxAge = ages.max() ?? point.ageMonths
        let pointX: CGFloat
        if maxAge > minAge {
            pointX = CGFloat(point.ageMonths - minAge) / CGFloat(maxAge - minAge) * size.width
        } else {
            pointX = size.width / 2
        }
        return CGPoint(x: pointX, y: yPosition(for: point.value, size: size))
    }
}
