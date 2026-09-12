import SwiftUI

/// LS-166（`design/littlesprout.pen` `LS-142 / 15 相簿詳情`）：相簿詳情瀑布流照片牆——每格是
/// 「白邊＋四角托」的沖印品（沿 `cmp/Photo Print`／`PhotoCornerOverlay` 既有母題，票文範圍 1），
/// 真實比例混排，不裁切。深色與亮色同幾何——`$print-paper`／角托顏色本身已隨深色模式換墨，
/// 這裡不需要另外分支。
///
/// 用 `HStack{ForEach 欄}{LazyVStack{ForEach 格}}` 而不是 `MasonryPhotoWallView`（LS-126
/// 日記詳情）那種 `ZStack`＋絕對定位——`AlbumPhotoGridLayout.place` 只回傳「每欄依序放哪些
/// 索引」，不算絕對座標（見該型別文件註解），欄內堆疊順序交給 SwiftUI 的 `VStack` 自然處理，
/// 比自己疊一層 `.position()` 更簡單、也更不容易在旋轉／字級變化時算錯。
///
/// **票文範圍 3「34 張壓測不掉幀（縮圖＋LazyVGrid）」**：這裡改用 `LazyVStack`（逐欄），不是
/// 字面上的 SwiftUI `LazyVGrid`——瀑布流本質是「各欄高度不同」的錯落版面，原生 `LazyVGrid`
/// 是等高列（同一列的格子共用最高者的高度），無法產生真正的 masonry 版面，`MasonryPhotoWallView`
/// （LS-126）踩過同一個限制、也是用 `ZStack` 絕對定位而不是 `LazyVGrid`。這裡要的效能目標
/// （縮圖延遲載入、捲動不掉幀）改用 `LazyVStack` 達成——只建構捲動可見範圍內的格子，34 張
/// 全滿也不會一次把每一張的 `AsyncImage` 都掛進 render tree。
struct AlbumPhotoGridView: View {
    let photos: [MediaContent]
    let containerWidth: CGFloat

    var body: some View {
        let result = AlbumPhotoGridLayout.place(aspectRatios: photos.map(\.aspectRatio), containerWidth: containerWidth)
        HStack(alignment: .top, spacing: AlbumPhotoGridLayout.columnGap) {
            ForEach(Array(result.columns.enumerated()), id: \.offset) { _, indices in
                LazyVStack(spacing: AlbumPhotoGridLayout.columnGap) {
                    ForEach(indices, id: \.self) { index in
                        AlbumPhotoPrintCell(photo: photos[index], columnWidth: result.columnWidth)
                    }
                }
                .frame(width: result.columnWidth, alignment: .top)
            }
        }
        .frame(width: containerWidth, alignment: .leading)
    }
}

/// 一格「白邊＋四角托」沖印品——同 `AlbumSummaryCardView.printCard`／`PrintPhotoCard` 的紙面
/// 母題結構，但這格**沒有 Caption／Imprint Row**（Notes `kHDk4` `vfPjM`：「空白 caption 型
/// 印品」），下緣白邊因此刻意留 32（`AlbumPhotoGridLayout.photoPaddingBottom`）而不是一般的
/// 8，讓角托依通式 `printH − 21` 落在 Notes 實測的 `wrapH + 19` 位置（見該型別文件註解）。
private struct AlbumPhotoPrintCell: View {
    let photo: MediaContent
    let columnWidth: CGFloat

    private static let cornerSize: CGFloat = 26
    /// Notes `kHDk4` `pVSXP` 板 `Print Cell` 節點四角染料池不透明度實測值——與
    /// `PrintPhotoCard.MountPoolOpacity.welcome` 不同（那組服務的是有 Caption 的沖印品），
    /// 這格沒有 Caption、染料池比例跟著版面改變，因此另建一組本地常數，不重用既有 preset
    /// （同 `AlbumSummaryCardView` 自己另建一份 `mountPoolGlow` 而不共用 `PrintPhotoCard`
    /// 私有實作的既有理由，見該檔文件註解）。
    private static let mountPoolTopLeading = 0.393
    private static let mountPoolTopTrailing = 0.259
    private static let mountPoolBottomLeading = 0.293
    private static let mountPoolBottomTrailing = 0.197

    var body: some View {
        let photoHeight = AlbumPhotoGridLayout.photoHeight(forRatio: photo.aspectRatio, columnWidth: columnWidth)
        let photoWidth = AlbumPhotoGridLayout.photoWidth(columnWidth: columnWidth)
        photoImage
            .frame(width: photoWidth, height: photoHeight)
            .clipped()
            .padding(.top, AlbumPhotoGridLayout.photoPaddingTop)
            .padding(.horizontal, AlbumPhotoGridLayout.photoPaddingHorizontal)
            .padding(.bottom, AlbumPhotoGridLayout.photoPaddingBottom)
            .frame(width: columnWidth, alignment: .leading)
            .background(mountPoolGlow.clipped())
            .background(Color.lsPrintPaper)
            .overlay(PhotoCornerOverlay(size: Self.cornerSize))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(photo.type == .video ? "影片" : "照片")
            .accessibilityAddTraits(.isImage)
    }

    private var photoImage: some View {
        Group {
            if let url = photo.signedURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.lsSurface2
                    }
                }
            } else {
                Color.lsSurface2
            }
        }
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter = Self.cornerSize * 6
            ZStack {
                glow(diameter: diameter, opacity: Self.mountPoolTopLeading).position(x: 0, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolTopTrailing).position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolBottomLeading).position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: Self.mountPoolBottomTrailing)
                    .position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }

    private func glow(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.lsMountPool.opacity(opacity), Color.lsMountPoolFade],
                    center: .center, startRadius: 0, endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        AlbumPhotoGridView(
            photos: [
                MediaContent(
                    id: UUID(), type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "a.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ),
                MediaContent(
                    id: UUID(), type: .photo, width: 1, height: 1, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "b.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ),
                MediaContent(
                    id: UUID(), type: .photo, width: 3, height: 4, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "c.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                )
            ],
            containerWidth: 345
        )
        .padding()
    }
}
#endif
