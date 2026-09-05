import SwiftUI

/// 相簿 tab 首頁卡片（`cmp/Card Album`，LS-165 依 LS-142 稿）——沖印品母題封面＋Caption
/// （相簿名＋張數）＋Signature Line（署名列）＋扇影厚度分級。
///
/// 與 `LittleSprout/DesignSystem/PrintPhotoCard.swift` 結構相似（白邊＋角托＋染料池）但另建
/// 一份小型版本，不重用該元件——同 `AvatarPrintCard` 文件註解的既有理由：這裡的「紙」要往下
/// 延伸包住 Caption／Signature 兩行文字（角托落在整張卡片最下緣，不是只包住照片本身，見
/// LS-142 Handoff Notes `piK2I`／核可頁截圖 `puHZ5.png`），`PrintPhotoCard` 本身的
/// `imprintRow` 固定印 "LITTLE SPROUT" 品牌字樣、不接受任意內容，形狀對不上。
///
/// `cardWidth` 由呼叫端（`AlbumsView`）量好傳入，不在這裡用 `GeometryReader` 自我量寬——同
/// `DiaryCardView.previewRowWidth` 文件註解點名的既有陷阱（子節點固定寬會把自我量測撐大）。
struct AlbumSummaryCardView: View {
    let album: AlbumSummary
    /// 依 `ChildrenStore.children` 原本順序（依 birthday 排序）解析出的寶貝——呼叫端算好
    /// 傳入，同 `TimelineView.taggedChildren(for:)` 既有分工（`AlbumSummary` 只留
    /// `childIds`，見該檔文件註解）。
    let taggedChildren: [Child]
    let cardWidth: CGFloat
    var photoHeight: CGFloat = 184
    var cornerSize: CGFloat = 26

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// AX3 起署名列一行一人、Caption 相簿名與張數各自成行——同 `SectionTabBar.isAX3` 既有
    /// 斷點慣例（LS-142 Handoff Notes `MJ-6`／`R4 KBNSX`：兩態切換，不是連續縮放曲線）。
    private var isOneLinePerPerson: Bool { dynamicTypeSize >= .accessibility3 }

    var body: some View {
        // `.frame(maxWidth: .infinity)`（不是 `.frame(width: cardWidth)`）——同
        // `DiaryCardView` 頂層既有寫法：卡片本身接受父層真正給的提案寬度，`cardWidth`
        // 只餵給 `AlbumFanGhostLayer` 算扇影比例縮放，不拿來限制卡片外框寬度，避免呼叫端
        // （`AlbumsView`）量寬時卡片用自己的（可能過期的）狀態值把測到的寬度鎖死、量不到
        // 真正的可用寬（見 `DiaryCardView.previewRowWidth` 文件註解點名的既有陷阱）。
        ZStack(alignment: .topLeading) {
            AlbumFanGhostLayer(tier: album.thicknessTier, cardWidth: cardWidth)
            printCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var printCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            photo
            captionBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(mountPoolGlow.clipped())
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: cornerSize))
    }

    private var photo: some View {
        ZStack {
            Color.lsSurface2
            if let url = album.cover?.signedURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            } else {
                Image(systemName: "photo.stack")
                    .font(.system(size: photoHeight * 0.3))
                    .foregroundStyle(Color.lsTextSecondary.opacity(0.5))
            }
            Color.lsPhotoDim
        }
        .frame(height: photoHeight)
        .clipped()
    }

    /// Caption（相簿名＋張數）／Signature Line（署名列）文字格式見
    /// `AlbumSignatureFormatter`——這裡只負責排版與 token 套用，不重複格式規則。年齡以「現在」
    /// 為準（不是 `album.createdAt`）：相簿是持續累積的收藏容器，不像日記有單一「發生當下」，
    /// 署名列的角色是「這本相簿收錄了誰、現在幾歲」的家族名條，不是記憶時間戳（核可頁截圖
    /// `X9PfG.png` 同一個孩子在不同相簿卡片顯示同一個年齡，佐證這個判讀）。
    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text(AlbumSignatureFormatter.captionText(
                title: album.title, photoCount: album.photoCount, isMultiline: isOneLinePerPerson
            ))
            .appNumericFont(.body, weight: .semibold)
            .foregroundStyle(Color.lsPrintInk)
            Text(AlbumSignatureFormatter.signatureText(
                children: taggedChildren, asOf: Date(), isOneLinePerPerson: isOneLinePerPerson
            ))
            .appNumericFont(.meta)
            .foregroundStyle(Color.lsPrintInkSecondary)
        }
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter = cornerSize * 6
            ZStack {
                glow(diameter: diameter, opacity: PrintPhotoCard.MountPoolOpacity.welcome.topLeading)
                    .position(x: 0, y: 0)
                glow(diameter: diameter, opacity: PrintPhotoCard.MountPoolOpacity.welcome.topTrailing)
                    .position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: PrintPhotoCard.MountPoolOpacity.welcome.bottomLeading)
                    .position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: PrintPhotoCard.MountPoolOpacity.welcome.bottomTrailing)
                    .position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }

    private func glow(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.lsMountPool.opacity(opacity), Color.lsMountPoolFade],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

/// 卡底扇影（LS-142 Handoff Notes `EBlnw`）——相簿「有多厚」唯一的視覺訊號：1–9 張 1 片／
/// 10–49 張 2 片／50+ 張 3 片，畫在 Photo Print 之前（z-order `[Ghost3, Ghost1, Ghost2,
/// PhotoPrint]`）。三片的 `x`／`w` 依卡寬等比縮放（LS-142 iPad 換算比例
/// `258.5/345≈0.7493` 反推 iPhone 基準值），`y`／`rotation` 為固定值、不隨卡寬縮放（Notes
/// 明記「iPad 皆按卡寬比例縮放...y／rotation 與 iPhone 相同」）。
private struct AlbumFanGhostLayer: View {
    let tier: AlbumThicknessTier
    let cardWidth: CGFloat

    private struct Ghost {
        let offsetX: CGFloat
        let offsetY: CGFloat
        let width: CGFloat
        let height: CGFloat
        let rotation: Double
    }

    /// 基準卡寬（iPhone 393pt 螢幕扣兩側 `$screen-pad` 24pt）——`AlbumsModels.swift` 一類
    /// 純幾何常數不掛 `AppSpacing`，因為這組數字是這個元件獨有的稿面實測值，不是全站共用間距
    /// token。
    private static let referenceCardWidth: CGFloat = 345
    private static let ghost1 = Ghost(offsetX: 90, offsetY: -18, width: 165, height: 50, rotation: -3)
    private static let ghost2 = Ghost(offsetX: 108, offsetY: -11, width: 140, height: 50, rotation: 2)
    private static let ghost3 = Ghost(offsetX: 72, offsetY: -18, width: 150, height: 50, rotation: -6)

    var body: some View {
        // 畫的順序＝z-order（先畫在下方）：Ghost3 最先，Ghost1／Ghost2 依張數門檻疊加。
        ZStack(alignment: .topLeading) {
            if tier.fanGhostCount >= 3 { ghostView(Self.ghost3) }
            if tier.fanGhostCount >= 1 { ghostView(Self.ghost1) }
            if tier.fanGhostCount >= 2 { ghostView(Self.ghost2) }
        }
    }

    private var scale: CGFloat { cardWidth / Self.referenceCardWidth }

    private func ghostView(_ ghost: Ghost) -> some View {
        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium * 0.6)
            .fill(Color.lsPrintPaper)
            .shadow(color: Color.lsPaperShadow, radius: 2, x: 0, y: 1)
            .frame(width: ghost.width * scale, height: ghost.height * scale)
            .rotationEffect(.degrees(ghost.rotation))
            .offset(x: ghost.offsetX * scale, y: ghost.offsetY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: AppSpacing.tight) {
            AlbumSummaryCardView(
                album: AlbumSummary(
                    id: UUID(), title: "上禮拜的動物園一日遊", photoCount: 12, cover: nil, childIds: [],
                    createdAt: Date()
                ),
                taggedChildren: [
                    Child(id: UUID(), name: "小安", birthday: Date(), avatarURL: nil, deletedAt: nil, createdAt: Date())
                ],
                cardWidth: 345
            )
            AlbumSummaryCardView(
                album: AlbumSummary(
                    id: UUID(), title: "跨年連假出遊", photoCount: 62, cover: nil, childIds: [], createdAt: Date()
                ),
                taggedChildren: [],
                cardWidth: 345
            )
        }
        .padding()
    }
}
#endif
