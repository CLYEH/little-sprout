import SwiftUI

/// LS-410（`design/littlesprout.pen` `sq2SF`／`KYq7n`）：上傳佇列 sheet 全部完成態的 3 欄正方縮圖格——這是整個流程
/// 唯一的好消息，照片是主角。格寬＝(內容欄 − 2×`$sp-label`)/3、圓角 2、無白邊無角托（還在路上的照片不是沖印品）；
/// 無群標題、無時間戳、無狀態列；K 大時外層 `ScrollView` 捲動、格子不縮。
///
/// **不可點**（C1a，使用者 2026-09-30 核可）：整格 `allowsHitTesting(false)`——無按壓態、不導航，也不掛 button
/// trait；每格只有 accessibility label「今天 14:35 加進相簿的照片」（時間取 `enqueuedAt`）。「關閉」是唯一動作。
struct UploadQueueDoneGrid: View {
    struct Item: Identifiable {
        let id: UUID
        let enqueuedAt: Date
        let thumbnail: UIImage?
    }

    let items: [Item]

    private static let columnCount = 3

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.label), count: Self.columnCount),
            spacing: AppSpacing.label
        ) {
            ForEach(items) { item in
                cell(item)
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        Color.lsSurface2
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("\(UploadQueueTimestampFormat.string(for: item.enqueuedAt)) 加進相簿的照片")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(QAAccessibilityID.uploadQueueDonePhoto)
    }
}
