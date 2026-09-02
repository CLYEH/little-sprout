import SwiftUI

/// 時間軸照片卡（`cmp/Card Photo`，LS-126 票文 Scope 1）——沖印品母題單張照片／影片縮圖。
/// 影片顯示「影片 M:SS」徽章，**不自動播放、不內嵌播放器**（票文明文要求）——這裡只畫靜態
/// 縮圖＋徽章，完全沒有 `AVPlayer` 相關的 View。
///
/// 純顯示元件，不含導覽（票文 Scope 1 只描述時間軸主畫面的卡片外觀，沒有要求主時間軸的
/// 照片卡本身要能點開全螢幕——那個行為只在日記詳情的瀑布流照片牆才有，見
/// `MasonryPhotoWallView`／`VideoPlayerScreen`）。
struct PhotoCardView: View {
    let content: MediaContent
    let timelineStore: TimelineStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PrintPhotoCard(
                photoHeight: 220,
                showsImprint: false,
                remoteURL: content.signedURL,
                accessibilityLabel: accessibilityLabel
            )
            if content.type == .video {
                // `showsImprint: false` 時 PrintPhotoCard 底部只有 `printEdgeBottom`（8）留白
                // （沒有壓印行那 7+17），徽章貼著照片內緣、再空一個 `sp-label`（8）出來。
                videoBadge
                    .padding(.leading, AppSpacing.printEdge + AppSpacing.label)
                    .padding(.bottom, AppSpacing.printEdgeBottom + AppSpacing.label)
            }
        }
        .task(id: content.id) {
            guard content.type == .video, let url = content.signedURL else { return }
            await timelineStore.loadVideoDuration(mediaID: content.id, url: url)
        }
    }

    private var accessibilityLabel: String {
        content.type == .video ? VideoDurationFormat.badgeText(duration: duration) : "照片"
    }

    private var duration: TimeInterval? {
        timelineStore.videoDurations[content.id]
    }

    private var videoBadge: some View {
        Text(VideoDurationFormat.badgeText(duration: duration))
            .appFont(.note, weight: .bold)
            .foregroundStyle(Color.lsOnPhoto)
            .padding(.horizontal, AppSpacing.group)
            .padding(.vertical, AppSpacing.tight)
            .background(Color.black.opacity(0.55), in: Capsule())
            .accessibilityHidden(true) // 已併入 PrintPhotoCard 的 accessibilityLabel。
    }
}

#Preview {
    VStack(spacing: AppSpacing.item) {
        PhotoCardView(
            content: MediaContent(id: UUID(), type: .photo, width: 4, height: 3, signedURL: nil),
            timelineStore: .preview()
        )
        PhotoCardView(
            content: MediaContent(id: UUID(), type: .video, width: 16, height: 9, signedURL: nil),
            timelineStore: .preview()
        )
    }
    .padding()
}
