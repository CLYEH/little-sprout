import SwiftUI

/// 飲食圖鑑 8 類分頁（02 `u5V1Ru` Category Tabs；Notes `v5KLRQ`）：全部可見、不橫捲——一般字級 2 列 ×
/// 4 欄，AX 字級 4 列 × 2 欄（A11y/02 `x3aELx`）。
///
/// 選中＝`$print-paper`＋2pt `$print-ink` 框＋17 bold `$print-ink`；未選＝透明＋`$control-line` 1pt＋17
/// regular `$text-secondary`（MN-2）。欄距：iPhone 一般字級 `$sp-tight`（6），iPad 與 AX3 `$sp-label`
/// （8）——三張板各自的 Tab Row gap 值；列距一律 `$sp-label`。
///
/// 同一列的分頁等高（`HStack.fixedSize(vertical:)`＋子項 `maxHeight: .infinity`）：某一格字級大到折兩行
/// 時，同列其他格跟著長高，框線不會高低不齊。
struct FoodCategoryTabs: View {
    @Binding var selection: FoodCategory
    let columns: Int
    let columnSpacing: CGFloat

    var body: some View {
        VStack(spacing: AppSpacing.label) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: columnSpacing) {
                    ForEach(row) { category in
                        tab(category)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [[FoodCategory]] {
        let all = FoodCategory.allCases
        return stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
    }

    static func accessibilityID(_ category: FoodCategory) -> String { "foodTab.\(category.rawValue)" }

    private func tab(_ category: FoodCategory) -> some View {
        let isSelected = category == selection
        let shape = RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        return Button {
            selection = category
        } label: {
            Text(category.displayName)
                .appFont(.body, weight: isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? Color.lsPrintInk : Color.lsTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, AppSpacing.controlPaddingTap)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background {
                    if isSelected {
                        shape.fill(Color.lsPrintPaper)
                            .overlay(shape.strokeBorder(Color.lsPrintInk, lineWidth: 2))
                    } else {
                        shape.strokeBorder(Color.lsControlLine, lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(Self.accessibilityID(category))
    }
}
