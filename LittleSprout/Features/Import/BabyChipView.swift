import SwiftUI

/// `cmp/Baby Chip`（`design/littlesprout.pen` LS-251 R1 handoff `o9Brs1`）——匯入整理頁群卡
/// 內的多選寶貝膠囊。**不是** `AttributionSheet` 那種滿寬列（那是 LS-47 既有的日記歸屬多選
/// 語彙，行內排版）；這裡是可並排的緊湊 chip，多顆時自動換行（`BabyChipRow`）。
///
/// 選中＝`$accent-soft` 底＋`$text-primary` 頭像／勾號實心；未選中＝`$surface` 底＋
/// `$control-line` 外框＋灰勾號外框。頭像 32×32（沿用既有 `ChildAvatarView`，同尺寸初始字級
/// ≈12pt，貼近設計稿 `$fs-imprint` token，見 `ChildAvatarView` 文件註解：縮寫本身不吃
/// Dynamic Type）。
struct BabyChipView: View {
    let child: Child
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                ChildAvatarView(name: child.name, size: 32)
                Text(child.name).appFont(.body, weight: .semibold).foregroundStyle(Color.lsTextPrimary)
                checkmark
            }
            .padding(.vertical, AppSpacing.tight)
            .padding(.horizontal, AppSpacing.label)
            .frame(minHeight: 48)
            .background(
                isSelected ? Color.lsAccentSoft : Color.lsSurface, in: Capsule()
            )
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(child.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var checkmark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .appIconFrame(.small)
            .foregroundStyle(isSelected ? Color.lsTextPrimary : Color.lsTextSecondary)
    }
}

/// 多顆 `BabyChipView` 自動換行排列——家庭寶貝數通常個位數，用簡單的
/// `Layout`（iOS 16+）換行即可，不需要引入完整的瀑布流演算法。
struct BabyChipRow: View {
    let children: [Child]
    let selectedChildIDs: Set<UUID>
    let onToggle: (UUID) -> Void

    var body: some View {
        WrapLayout(spacing: AppSpacing.label) {
            ForEach(children) { child in
                BabyChipView(
                    child: child, isSelected: selectedChildIDs.contains(child.id),
                    action: { onToggle(child.id) }
                )
            }
        }
    }
}

/// 最小可用的自動換行版面——依序把子視圖排進目前這一列，寬度放不下才換下一列。沒有欄
/// 對齊／等寬需求（chip 寬度隨名字長短自然變化），比引入第三方或自建瀑布流演算法簡單。
struct WrapLayout: Layout {
    var spacing: CGFloat = AppSpacing.label

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var originX = bounds.minX
        var originY = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if originX > bounds.minX, originX + size.width > bounds.maxX {
                originX = bounds.minX
                originY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: originX, y: originY), proposal: ProposedViewSize(size))
            originX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview {
    BabyChipRow(
        children: [
            Child(id: UUID(), name: "陳小安", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date()),
            Child(id: UUID(), name: "陳小軒", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date())
        ],
        selectedChildIDs: [], onToggle: { _ in }
    )
    .padding()
}
#endif
