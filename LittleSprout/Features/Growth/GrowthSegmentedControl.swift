import SwiftUI

/// `cmp/Segmented`（Notes `c8ZCKX`，抄值表元件 id `SEy9U`）——成長曲線卡的身高／體重／頭圍
/// 切換。AX3（`.accessibility3` 以上）改直式堆疊（Notes：「AX3 版全部改直式堆疊
/// （layout:vertical）」）；一般字級維持橫向三段式。每段可點區 `minHeight 48`（品牌硬約束：
/// 任何按鈕不得 `.disabled(`，這裡三段永遠都可點，只是視覺上以填色區分目前選取哪一段）。
struct GrowthSegmentedControl: View {
    @Binding var selection: GrowthMetric
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isVerticalLayout: Bool { dynamicTypeSize >= .accessibility3 }

    var body: some View {
        Group {
            if isVerticalLayout {
                VStack(spacing: AppSpacing.tight) { segments }
            } else {
                HStack(spacing: AppSpacing.tight) { segments }
            }
        }
        .padding(AppSpacing.tight)
        .background(Color.lsPrintInk.opacity(0.06), in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    private var segments: some View {
        ForEach(GrowthMetric.allCases) { metric in
            Button {
                selection = metric
            } label: {
                Text(metric.label)
                    .appFont(.note, weight: selection == metric ? .bold : .regular)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selection == metric ? Color.lsPrintInk : Color.lsPrintInkSecondary)
                    .background(
                        selection == metric ? Color.lsPrintPaper : Color.clear,
                        in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium - 2)
                    )
            }
            .accessibilityAddTraits(selection == metric ? [.isSelected] : [])
        }
    }
}

#Preview {
    GrowthSegmentedControl(selection: .constant(.height))
        .padding()
        .background(Color.lsPrintPaper)
}
