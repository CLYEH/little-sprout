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
            // R2-M1（merge-review `b7ecfbf4`）：`isThumbnail` 時 `signedURL` 是縮圖 JPEG，
            // 不是可解出時長的影片檔——讀取必定失敗，從源頭跳過，不要浪費一次網路請求
            // （`TimelineStore.loadVideoDuration` 的 `failedDurations` 是給其他失敗情境的
            // 硬化，兩者互補，這裡不能只靠那一層擋，縮圖列連第一次嘗試都不該發生）。
            guard content.needsVideoDurationLookup, let url = content.signedURL else { return }
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
        // fix/LS-130-video-badge-fallback：樣式抽到 `VideoDurationBadge`（`DiaryCardView`
        // 附照預覽縮圖現在也用同一套），這裡的視覺輸出不變。
        VideoDurationBadge(duration: duration)
            .accessibilityHidden(true) // 已併入 PrintPhotoCard 的 accessibilityLabel。
    }
}

#Preview {
    VStack(spacing: AppSpacing.item) {
        PhotoCardView(
            content: MediaContent(
                id: UUID(), type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/photo.jpg", isThumbnail: false, signedURL: nil
            ),
            timelineStore: .preview()
        )
        PhotoCardView(
            content: MediaContent(
                id: UUID(), type: .video, width: 16, height: 9, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/video.mp4", isThumbnail: false, signedURL: nil
            ),
            timelineStore: .preview()
        )
    }
    .padding()
}
