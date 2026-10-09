import SwiftUI

/// 04 的旋轉日期章（`cmp/Day Divider` `oLN0e` 實例 `n8uwKm`）：Stamp（`$print-paper` 底、`$print-ink-secondary`
/// 1.5 框、`rotation −4`、`$paper-shadow` 0/2/6）疊在 Ghost（同框同底、`opacity 0.45`、`rotation −1`、位移 −3/+3）
/// 之上；文字 `$print-ink-secondary` 700、字距 0.3，預設 `$fs-lead` 單行，AX 字級 `$fs-note` 兩行（`BwfLB`）。
/// 旋轉角直接照稿面數值套 `rotationEffect`（同 `AlbumFanGhostLayer` 的既有換算）。
///
/// VoiceOver 念單行版（兩行版的換行只是視覺斷點），Ghost 不念。
struct FoodFirstTriedStamp: View {
    let firstTriedOn: Date
    let isAccessibilityLayout: Bool

    var body: some View {
        let text = FoodRecordDetailCopy.stampText(firstTriedOn: firstTriedOn, twoLines: isAccessibilityLayout)
        ZStack(alignment: .topLeading) {
            face(text)
                .opacity(0.45)
                .rotationEffect(.degrees(-1))
                .offset(x: -3, y: 3)
                .accessibilityHidden(true)
            face(text)
                .shadow(color: .lsPaperShadow, radius: 3, x: 0, y: 2)
                .rotationEffect(.degrees(-4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FoodRecordDetailCopy.stampText(firstTriedOn: firstTriedOn, twoLines: false))
        .accessibilityIdentifier("foodRecordDetail.stamp")
    }

    private func face(_ text: String) -> some View {
        Text(text)
            .appFont(isAccessibilityLayout ? .note : .lead, weight: .bold)
            .tracking(0.3)
            .foregroundStyle(Color.lsPrintInkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, AppSpacing.tight)
            .padding(.horizontal, AppSpacing.label)
            .background(Color.lsPrintPaper)
            .overlay(Rectangle().strokeBorder(Color.lsPrintInkSecondary, lineWidth: 1.5))
    }
}

/// 04 的沖印品（`fpjli` Photo Print／04b `VUwdZ` Blank Print）：`$print-paper` 台紙、`$paper-edge` 1pt、
/// `$paper-shadow` 2/8 blur 16、`$print-edge` 白邊、gap 7，下方壓印行「暱稱 · 年齡」。
///
/// - 有照片：對角兩顆角托（Corner TL／Corner BR，`cmp/Photo Corner` 26pt、外擴 5，沿 `cmp/Card Photo` 印品
///   家族），台紙兩顆染料池（左上／右下；iPad 值另計）；深色疊 `$photo-dim`。
/// - 沒有照片（04b）：同幾何、**零角托**、無染料池（Notes `hqrit`「空白沖印品（同 04 幾何、零角托）」）；照片窗
///   填 `$print-ink-secondary` 12%，作者看到 image-plus＋「加一張第一次吃〇〇的照片」、整張可點（開照片來源）；
///   其他人（04d `P2EIHz`）看到窗內「這筆沒有照片」——regular、`$print-ink-secondary`、無 icon、不是按鈕。
struct FoodRecordPrint: View {
    struct MountPool {
        let topLeading: Double
        let bottomTrailing: Double
        /// `fpjli` 兩顆漸層（0.382／0.116）。
        static let compact = MountPool(topLeading: 0.382, bottomTrailing: 0.116)
        /// 04-iPad `Ea1T5`（0.31／0.033）。
        static let regular = MountPool(topLeading: 0.31, bottomTrailing: 0.033)
    }

    let photo: FoodRecordDetailPhotoState
    let photoHeight: CGFloat
    let caption: String
    let mountPool: MountPool
    let addPhotoLabel: String
    /// 非 nil＝目前登入者可以補照片（作者），04b 整張是按鈕。
    let onAddPhoto: (() -> Void)?

    static let cornerSize: CGFloat = 26

    /// 角托只在有照片時出現、且只有對角兩顆——`FoodRecordDetailCopyTests` 鎖住這條規則。
    static func corners(hasPhoto: Bool) -> [PhotoCorner] {
        hasPhoto ? [.topLeading, .bottomTrailing] : []
    }

    private var hasPhoto: Bool { photo != .none }

    var body: some View {
        if !hasPhoto, let onAddPhoto {
            Button(action: onAddPhoto) { printBody }
                .buttonStyle(.plain)
                .accessibilityLabel(addPhotoLabel)
                .accessibilityIdentifier("foodRecordDetail.addPhoto")
        } else {
            printBody
        }
    }

    private var printBody: some View {
        VStack(spacing: 7) {
            window
            Text(caption)
                .appFont(.body)
                .foregroundStyle(Color.lsPrintInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodRecordDetail.imprint")
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background {
            ZStack {
                Rectangle().fill(Color.lsPrintPaper)
                    .shadow(color: .lsPaperShadow, radius: 8, x: 2, y: 8)
                if hasPhoto { mountPoolGlow }
            }
        }
        .overlay(Rectangle().strokeBorder(Color.lsPaperEdge, lineWidth: 1))
        .overlay { corners }
    }

    @ViewBuilder
    private var window: some View {
        switch photo {
        case .none:
            blankWindow
        case .loading, .unavailable:
            Color.lsSurface2.frame(height: photoHeight)
                .accessibilityHidden(true)
        case .loaded(let url):
            // 照片窗以固定高度的底色為本體、照片疊在 overlay 並裁切：蓋滿（scaledToFill）的圖本身會比窗大
            // （直式 4:3 圖在 338×400 窗內是 338×507），若把它當無障礙元素，frame 會撐出沖印品；圖片本身
            // 藏起來，「照片」標籤掛在固定大小的底色上，VoiceOver 焦點框與 UITest 量到的就是照片窗本身。
            Color.lsSurface2
                .frame(height: photoHeight)
                .accessibilityElement()
                .accessibilityLabel("照片")
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("foodRecordDetail.photo")
                .overlay {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                    .accessibilityHidden(true)
                }
                .overlay(Color.lsPhotoDim.accessibilityHidden(true))
                .clipped()
        }
    }

    @ScaledMetric(relativeTo: .body) private var addIconSize: CGFloat = 40

    private var blankWindow: some View {
        ZStack {
            Color.lsPrintInkSecondary.opacity(0.12)
            if onAddPhoto != nil {
                VStack(spacing: AppSpacing.group) {
                    // 稿面 40（AX3 64）——跟著字級長大、上限 64，照片窗高度固定 400，不讓圖示擠掉文字。
                    Image(systemName: "photo.badge.plus")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(addIconSize, 64), height: min(addIconSize, 64))
                    Text(addPhotoLabel)
                        .appFont(.body, weight: .semibold)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.lsPrintInk)
                .padding(.horizontal, AppSpacing.insetCard)
            } else {
                // 04d：唯讀的一句話，不做成按鈕（無 icon、無粗體、無 chevron；VoiceOver 不加 `.isButton`）。
                Text(FoodRecordDetailCopy.noPhoto)
                    .appFont(.body)
                    .foregroundStyle(Color.lsPrintInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.insetCard)
                    .accessibilityIdentifier("foodRecordDetail.noPhoto")
            }
        }
        .frame(height: photoHeight)
    }

    /// 兩顆染料池：以台紙角為圓心、半徑 78（＝角托 26×6 的直徑一半，同 `PrintPhotoCard.mountPoolGlow`）的放射漸層，
    /// 直接畫在台紙矩形內——不用「圓心在角上的圓＋clipped」：那個圓的 frame 會溢出台紙 78pt，把沖印品的
    /// 無障礙 frame 撐大（UITest 量角托時抓到）。
    private var mountPoolGlow: some View {
        let radius = Self.cornerSize * 3
        return ZStack {
            Rectangle().fill(RadialGradient(
                colors: [Color.lsMountPool.opacity(mountPool.topLeading), Color.lsMountPoolFade],
                center: .topLeading, startRadius: 0, endRadius: radius
            ))
            Rectangle().fill(RadialGradient(
                colors: [Color.lsMountPool.opacity(mountPool.bottomTrailing), Color.lsMountPoolFade],
                center: .bottomTrailing, startRadius: 0, endRadius: radius
            ))
        }
        .allowsHitTesting(false)
    }

    private var corners: some View {
        ZStack {
            ForEach(Self.corners(hasPhoto: hasPhoto), id: \.self) { corner in
                cornerView(corner)
            }
        }
        .accessibilityHidden(true)
    }

    /// 同 `PhotoCornerOverlay.cornerView` 的畫法（`PhotoCornerShape`＋摺痕、外擴 `cornerOut`）；畫哪幾顆由 `corners(hasPhoto:)` 決定。
    private func cornerView(_ corner: PhotoCorner) -> some View {
        let shape = PhotoCornerShape(corner: corner)
        let size = Self.cornerSize
        let out = AppSpacing.cornerOut
        let isLeading = corner == .topLeading || corner == .bottomLeading
        let isTop = corner == .topLeading || corner == .topTrailing
        return ZStack {
            shape.fill(Color.lsPhotoCorner)
            shape.foldEdge(in: CGRect(x: 0, y: 0, width: size, height: size))
                .stroke(Color.lsCornerFold, lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: Alignment(horizontal: isLeading ? .leading : .trailing, vertical: isTop ? .top : .bottom)
        )
        .offset(x: isLeading ? -out : out, y: isTop ? -out : out)
    }
}

/// Reaction Chip（`m9RG7L`）：`$accent-soft` 膠囊、padding `$sp-label`／`$sp-item`、gap `$sp-tight`；臉 22（AX3 40）
/// ＋文字 `$fs-body` 700 `$text-primary`。
struct FoodRecordReactionChip: View {
    let reaction: FoodReaction

    var body: some View {
        HStack(spacing: AppSpacing.tight) {
            // LS-380 併入後改用 03 sheet 同一支臉（`FoodReactionIcon`，同一套 lucide 幾何），不各畫一份。
            FoodReactionIcon(reaction: reaction)
                .appIconFrame(.medium)
            Text(reaction.label).appFont(.body, weight: .bold)
        }
        .foregroundStyle(Color.lsTextPrimary)
        .padding(.vertical, AppSpacing.label)
        .padding(.horizontal, AppSpacing.item)
        .background(Color.lsAccentSoft, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("foodRecordDetail.reaction")
    }
}

/// 「編輯這筆記錄」（`cmp/Button Secondary` `XggYA`）：無填色、`$control-line` 1.5 框、`$radius-md`、padding
/// `$ctl-pad-md`／20、pencil 22＋`$fs-body` 600 `$text-primary`，全寬。
struct FoodRecordEditButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "pencil").appIconFrame(.medium)
                Text(FoodRecordDetailCopy.editTitle).appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("foodRecordDetail.edit")
    }
}

/// 「刪除這筆記錄」（04c `dreeR`，`cmp/Button Text` `qe9yS`）：trash 22＋`$fs-body` 600，皆 `$danger`，全寬置中。
/// 稿面 padding `$ctl-pad-tap`（9.5）只有 41pt 高，補 `minHeight 48` 過點擊目標硬約束。
struct FoodRecordDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "trash").appIconFrame(.medium)
                Text(FoodRecordDetailCopy.deleteTitle).appFont(.body, weight: .semibold)
            }
            .foregroundStyle(Color.lsDanger)
            .padding(.vertical, AppSpacing.controlPaddingTap)
            .padding(.horizontal, AppSpacing.tight)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("foodRecordDetail.delete")
    }
}
