import SwiftUI

/// 日記詳情瀑布流照片牆（LS-126 票文 Scope 2）——依 `MasonryLayout.place` 算出的座標把每張
/// 照片放上去，每張等比縮到欄寬、不裁切；子視圖依原始陣列順序加入 `ZStack`，VoiceOver 順序
/// 因此＝原始順序（見 `MasonryLayout` 文件註解），不需要另外排序。
struct MasonryPhotoWallView: View {
    let photos: [MediaContent]
    let containerWidth: CGFloat
    let timelineStore: TimelineStore
    let onTapVideo: (MediaContent) -> Void

    var body: some View {
        let result = MasonryLayout.place(aspectRatios: photos.map(\.aspectRatio), containerWidth: containerWidth)
        let items = Array(zip(photos, result.placements).enumerated())
        ZStack(alignment: .topLeading) {
            ForEach(items, id: \.element.0.id) { item in
                let photo = item.element.0
                let placement = item.element.1
                photoTile(photo)
                    .frame(width: placement.width, height: placement.height)
                    .position(x: placement.originX + placement.width / 2, y: placement.originY + placement.height / 2)
                    // merge-review R1「我沒審的範圍」：`.position` 絕對定位版面下，子視圖依
                    // 原始順序加入 `ZStack` 是否保證 VoiceOver 順序＝原始順序是 PLAUSIBLE、
                    // 未實跑 VoiceOver 驗證的推論——顯式釘住排序，不完全依賴這個推論成立。
                    .accessibilitySortPriority(Double(items.count - item.offset))
            }
        }
        .frame(width: containerWidth, height: result.contentHeight)
    }

    @ViewBuilder
    private func photoTile(_ photo: MediaContent) -> some View {
        ZStack {
            thumbnailImage(photo)
            if photo.type == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.lsOnPhoto)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .contentShape(Rectangle())
        .onTapGesture {
            guard isPlayableVideo(photo) else { return }
            onTapVideo(photo)
        }
        .task(id: photo.id) {
            guard photo.type == .video, let url = photo.signedURL else { return }
            await timelineStore.loadVideoDuration(mediaID: photo.id, url: url)
        }
        .accessibilityLabel(accessibilityLabel(for: photo))
        .accessibilityAddTraits(isPlayableVideo(photo) ? [.isButton] : [.isImage])
    }

    /// merge-review R1 m4：簽名失敗（`signedURL == nil`）的影片格不是真的可以點開播放
    /// ——tap 手勢與 accessibility trait 都要用同一個判斷，不能只擋其中一邊。
    private func isPlayableVideo(_ photo: MediaContent) -> Bool {
        photo.type == .video && photo.signedURL != nil
    }

    private func accessibilityLabel(for photo: MediaContent) -> String {
        guard photo.type == .video else { return "照片" }
        guard photo.signedURL != nil else { return "影片（暫時無法播放）" }
        return "\(VideoDurationFormat.badgeText(duration: timelineStore.videoDurations[photo.id]))，點兩下播放"
    }

    private func thumbnailImage(_ photo: MediaContent) -> some View {
        Group {
            if let url = photo.signedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.lsSurface2
                    }
                }
            } else {
                Color.lsSurface2
            }
        }
    }
}
