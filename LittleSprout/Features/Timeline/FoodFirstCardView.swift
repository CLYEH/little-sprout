import SwiftUI

/// 時間軸「第一次吃到〇〇」卡片（LS-383，`cmp/Card Food First` `SBzKx`；板 05 `SLjde`／深色 `QGdHY`／AX3 `CgmBD`）。
///
/// 稿面結構（由上而下，gap `$sp-group`、padding `$inset-card`）：
/// - Head Row（`aeP63`）：貼紙 72＋「第一次吃到〇〇」`$fs-body` 700 `$print-ink`＋反應列（臉 18＋`$fs-note` 600
///   `$print-ink-secondary`，沒選整列隱藏）；AX3 直排、靠左。
/// - Note（`MR5Yu`）：`$fs-body` regular `$print-ink`，沒寫就隱藏。
/// - Photo（`EL975`）：有照片才畫，滿寬、高 200、`$radius-md`、疊 `$photo-dim`（淺色透明、深色壓暗）。
/// - Book Row（`B3mnz`）：book-open 18＋「收進〇〇的飲食圖鑑 · 〈類別〉」`$fs-body` regular＋chevron-right 18，皆
///   `$print-ink-secondary`，點了開圖鑑並選到該類別（`TimelineRoute.foodBook(for:)`）；AX3 文字自然換行。
/// - Sign-off Rule（`y7xar`，`$paper-rule` 1pt）＋Signature（`Wqlnp`，靠右）：utensils＋名字＋「 · 年齡」；AX3 直排、靠右。
///
/// 紙卡材質（Notes `jQp2m`「同 cmp/Card Diary 材質，零角托」）：`$print-paper` 底、`$radius-lg`、`$paper-edge` 1pt
/// 外框、`$paper-shadow` 0/3 blur 12——紙不隨深色反轉（`print-*` token 本身保證），不另寫深色分支。
/// v1 沒有留言／愛心列（`food_first` 不是 `content_target_type`，範圍 4）。
///
/// 整張卡的導覽（點了開記錄詳情）由外層 `TimelineView.cardView(for:columns:)` 的 `NavigationLink` 負責，同
/// `DiaryCardView`；Book Row 是卡內另一個 `NavigationLink`，巢狀可點元件的觸控交給最深的那一層（同
/// `DiaryCardView` 內 `InteractionRow` 的既有情境）。
struct FoodFirstCardView: View {
    let content: FoodFirstContent
    let child: Child

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let stickerSize: CGFloat = 72
    static let photoHeight: CGFloat = 200

    /// 同 `FoodBookView`／`FoodRecordDetailView` 的門檻（AX1 起，稿面只畫 AX3）。
    private var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var sections: [FoodFirstCardCopy.Section] { FoodFirstCardCopy.sections(for: content) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            VStack(alignment: .leading, spacing: AppSpacing.group) {
                headRow
                if sections.contains(.note), let note = FoodFirstCardCopy.note(content.record) {
                    Text(note)
                        .appFont(.body)
                        .foregroundStyle(Color.lsPrintInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("foodFirstCard.note")
                }
                if sections.contains(.photo), let photo = content.photo {
                    photoView(photo)
                }
            }
            .accessibilityElement(children: .combine)
            bookRow
            Rectangle()
                .fill(Color.lsPaperRule)
                .frame(height: 1)
                .accessibilityHidden(true)
            signature
        }
        .padding(AppSpacing.insetCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .fill(Color.lsPrintPaper)
                .shadow(color: .lsPaperShadow, radius: 6, x: 0, y: 3)
        }
        // 稿面 stroke `outer`：外擴 1pt 的圓角框畫在卡片外緣之外，不吃掉內容區。
        .overlay {
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge + 1)
                .strokeBorder(Color.lsPaperEdge, lineWidth: 1)
                .padding(-1)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Head Row（`aeP63`）

    @ViewBuilder
    private var headRow: some View {
        let sticker = FoodStickerImage(foodID: content.item.id, size: Self.stickerSize, isGrayscale: false)
        let texts = VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(FoodFirstCardCopy.headline(foodName: content.item.nameZh))
                .appFont(.body, weight: .bold)
                .foregroundStyle(Color.lsPrintInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodFirstCard.headline")
            if let reaction = FoodFirstCardCopy.reaction(content.record) {
                HStack(spacing: AppSpacing.tight) {
                    FoodReactionIcon(reaction: reaction).appIconFrame(.small)
                    Text(reaction.label).appFont(.note, weight: .semibold)
                }
                .foregroundStyle(Color.lsPrintInkSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("foodFirstCard.reaction")
            }
        }
        if isAccessibilityLayout {
            VStack(alignment: .leading, spacing: AppSpacing.item) { sticker; texts }
        } else {
            HStack(spacing: AppSpacing.item) { sticker; texts }
        }
    }

    // MARK: - Photo（`EL975`）

    /// 照片窗以固定高度的底色為本體、照片疊在 overlay 並裁切（同 `FoodRecordPrint.window` 的理由：蓋滿的圖本身比
    /// 窗大，當無障礙元素會撐出卡片）。`signedURL` 是時間軸既有的縮圖簽名（`thumb_path` 優先）。
    private func photoView(_ photo: MediaContent) -> some View {
        Color.lsSurface2
            .frame(height: Self.photoHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                if let url = photo.signedURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .overlay(Color.lsPhotoDim.accessibilityHidden(true))
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .accessibilityElement()
            .accessibilityLabel("照片")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("foodFirstCard.photo")
    }

    // MARK: - Book Row（`B3mnz`）

    /// 卡內文字一律 `fixedSize(vertical:)`：稿面 `textGrowth: fixed-width`＝隨內容長高；AX3 實測在 `LazyVStack` 裡
    /// 不加會被截成「第一次吃到吐司…」。稿面列高 44（padding 9.5）；`minHeight 48` 多留點擊餘裕（同 `FoodRecordEditButton`），視覺內容不變。
    private var bookRow: some View {
        NavigationLink(value: TimelineRoute.foodBook(for: content)) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: "book").appIconFrame(.small).accessibilityHidden(true)
                Text(FoodFirstCardCopy.bookRowLabel(childName: child.name, category: content.item.category))
                    .appFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").appIconFrame(.small).accessibilityHidden(true)
            }
            .foregroundStyle(Color.lsPrintInkSecondary)
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(QAAccessibilityID.timelineFoodFirstBookRow)
    }

    // MARK: - Signature（`Wqlnp`）

    @ViewBuilder
    private var signature: some View {
        let parts = FoodFirstCardCopy.signature(child: child, firstTriedOn: content.record.firstTriedOn)
        let who = HStack(spacing: AppSpacing.tight) {
            Image(systemName: "fork.knife")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsPrintInkSecondary)
                .accessibilityHidden(true)
            Text(parts.name)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsPrintInk)
        }
        let age = Text(parts.age)
            .appFont(.note)
            .foregroundStyle(Color.lsPrintInkSecondary)
        Group {
            if isAccessibilityLayout {
                VStack(alignment: .trailing, spacing: 0) {
                    who
                    age.multilineTextAlignment(.trailing)
                }
            } else {
                HStack(spacing: AppSpacing.tight) { who; age }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("foodFirstCard.signature")
    }
}
