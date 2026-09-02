import SwiftUI

/// 疊在照片／縮圖上的影片時長徽章（`cmp/Card Photo` 既有樣式，LS-126）——深色膠囊＋白字，
/// 「影片」（尚未讀到時長／縮圖列不查）或「影片 M:SS」（讀到時長）。
///
/// fix/LS-130-video-badge-fallback：從 `PhotoCardView` 抽成共用元件，讓
/// `DiaryCardView` 的附照預覽縮圖也能用同一套樣式——修 QA R2 FAIL（`a999c9af`）：無縮圖
/// 舊影片在時間軸日記卡的附照預覽完全沒有任何徽章（`DiaryCardView.thumbnailImage` 原本
/// 對 `.video` 完全沒有特殊處理，`AsyncImage` 對 `.mov` 解不出圖片，退回空白 `Color.
/// lsSurface2` 矩形）。純樣式元件，不含定位——呼叫端決定要貼在卡片的哪個角落、要不要
/// `.accessibilityHidden`。
struct VideoDurationBadge: View {
    let duration: TimeInterval?

    var body: some View {
        Text(VideoDurationFormat.badgeText(duration: duration))
            .appFont(.note, weight: .bold)
            .foregroundStyle(Color.lsOnPhoto)
            .padding(.horizontal, AppSpacing.group)
            .padding(.vertical, AppSpacing.tight)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

#Preview {
    ZStack(alignment: .bottomLeading) {
        Color.gray
        VideoDurationBadge(duration: 68)
            .padding(AppSpacing.label)
    }
    .frame(width: 220, height: 140)
}
