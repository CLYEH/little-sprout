import SwiftUI

/// cmp/Food Cell（`design/littlesprout.pen` `IikhF`；LS-326 Notes `h752D`「紙＝吃過了」）。
///
/// 三態（`FoodCellState`）：
/// - 吃過：`$print-paper` 紙片（`$paper-edge` 1pt、`$paper-shadow` x1 y4 blur 8、`$radius-md`）＋彩色貼紙
///   ＋名稱 `$print-ink` 700＋日期 yyyy/M/d `$print-ink-secondary`。深色模式紙不反轉（`print-paper`
///   深色值仍是淺紙色、`print-ink` 單值，token 本身決定，這裡不分支）。
/// - 還沒吃：透明底＋`$border` 1pt 髮絲框、無落影；貼紙 App 端 `.saturation(0).opacity(0.6)` 即時灰階
///   （不用 `gray-preview/` 灰階圖檔，Notes `DpExV`）；名稱 `$text-secondary` 600；日期列放單一空白保住
///   列高（格子排版）。
/// - viewer 的空位（02c `jo5h8`）：同「還沒吃」但**連髮絲框都拿掉**，不是按鈕。
///
/// 兩種排版（`Layout`）：`grid`＝一般字級直排（貼紙 80、置中）；`list`＝AX 字級橫排清單（A11y/02
/// `x3aELx`：貼紙 96、靠上、文字靠左、padding 12/16、gap 16，空位可見「還沒吃過」）。
///
/// 小標（Tag Row／Tag Row 2）：過敏原「含〇〇」、「一歲後」各一行，純文字無圖示（F2a；稿面 Tag Icon
/// `enabled: false`）；紙上 `$print-ink-secondary`、紙外 `$text-secondary`，17／600。不看孩子年齡，滿一歲
/// 後仍顯示（D1a）。
struct FoodCell: View {
    enum Layout {
        case grid
        case list
    }

    let item: FoodCatalogItem
    let state: FoodCellState
    let layout: Layout
    /// 點擊回呼——`state.isInteractive == false`（viewer 空位）時不會包成按鈕，這個回呼不會被呼叫。
    let onTap: () -> Void

    private static let gridStickerSize: CGFloat = 80
    private static let listStickerSize: CGFloat = 96

    var body: some View {
        if state.isInteractive {
            Button(action: onTap) { styledContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier(Self.accessibilityID(item.id))
        } else {
            styledContent
                .accessibilityIdentifier(Self.accessibilityID(item.id))
        }
    }

    static func accessibilityID(_ foodID: String) -> String { "foodCell.\(foodID)" }

    private var styledContent: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout == .grid ? .top : .topLeading)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FoodBookCopy.cellAccessibilityLabel(item: item, state: state))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .grid:
            VStack(spacing: AppSpacing.tight) {
                FoodStickerImage(foodID: item.id, size: Self.gridStickerSize, isGrayscale: !state.isTried)
                textStack(alignment: .center)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, AppSpacing.tight)
        case .list:
            HStack(alignment: .top, spacing: AppSpacing.item) {
                FoodStickerImage(foodID: item.id, size: Self.listStickerSize, isGrayscale: !state.isTried)
                textStack(alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, AppSpacing.item)
        }
    }

    private func textStack(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        let frameAlignment: Alignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: AppSpacing.tight) {
            Text(item.nameZh)
                .appFont(.body, weight: state.isTried ? .bold : .semibold)
                .foregroundStyle(state.isTried ? Color.lsPrintInk : Color.lsTextSecondary)
            Text(dateLine)
                .appNumericFont(.note)
                .foregroundStyle(state.isTried ? Color.lsPrintInkSecondary : Color.lsTextSecondary)
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(state.isTried ? Color.lsPrintInkSecondary : Color.lsTextSecondary)
            }
        }
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    /// 吃過＝日期；還沒吃＝格子排版放單一空白（保住列高，稿面 `ac1Qk` 內容 " "）、清單排版放可見的
    /// 「還沒吃過」（Notes `vMFj3`：可見文字只在 AX3 橫排清單出現）。
    private var dateLine: String {
        if case .tried(let date) = state { return FoodBookCopy.cellDate(date) }
        return layout == .list ? FoodBookCopy.untriedText : " "
    }

    private var tags: [String] {
        [FoodBookCopy.allergenTag(item.allergens), FoodBookCopy.ageTag(minAgeMonths: item.minAgeMonths)]
            .compactMap { $0 }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
        switch state {
        case .tried:
            shape.fill(Color.lsPrintPaper)
                .overlay(shape.strokeBorder(Color.lsPaperEdge, lineWidth: 1))
                .shadow(color: .lsPaperShadow, radius: 4, x: 1, y: 4)
        case .untried:
            shape.strokeBorder(Color.lsBorder, lineWidth: 1)
        case .untriedReadOnly:
            Color.clear
        }
    }
}

/// 貼紙圖——解碼在 `FoodStickerLoader`（非主執行緒），載入前留同尺寸空白，不跳版。灰階＝
/// `.saturation(0).opacity(0.6)`（Notes `DpExV`）。
struct FoodStickerImage: View {
    let foodID: String
    let size: CGFloat
    let isGrayscale: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    /// 依顯示尺寸解碼（LS-379 R2，merge-review R1 M1）：80pt@3x＝240px，不解原圖 384px。
    private var pixelSize: Int { Int((size * displayScale).rounded(.up)) }

    var body: some View {
        Group {
            if let image = image ?? FoodStickerLoader.shared.cachedImage(for: foodID, pixelSize: pixelSize) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .saturation(isGrayscale ? 0 : 1)
        .opacity(isGrayscale ? 0.6 : 1)
        .accessibilityHidden(true)
        .task(id: "\(foodID)@\(pixelSize)") {
            image = await FoodStickerLoader.shared.image(for: foodID, pixelSize: pixelSize)
        }
    }
}
