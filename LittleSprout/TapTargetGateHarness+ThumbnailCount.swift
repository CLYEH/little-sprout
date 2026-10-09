#if DEBUG
import SwiftUI

/// LS-440：`ThumbnailCountLabel` 壓測 harness——`ThumbnailCountLabelUITests` 與截圖對稿用。
///
/// `LS_THUMBNAIL_COUNT_FIXTURE`：
/// - `import`（預設）：`ImportMoreCell` 在 96／64 格 × N＝3／28／128（壓測板 `foDYi`＋Notes `F3GbnN`
///   對照表二的一／兩／三位數），每格是 `accessibilityElement(.contain)` 容器、identifier
///   `thumbnailCount.cell.<邊長>.<N>`，UI test 可同時量格框與裡面那顆標籤。
/// - `diary`：真的 `DiaryCardView`，前 3 張＋「還有 N 張」暗蓋（`LS_THUMBNAIL_COUNT_REMAINING` 指定 N，預設 2）。
///
/// `LS_THUMBNAIL_COUNT_SCHEME=dark` 釘深色（同 `diaryCardBabyCaptionHost`）；字級用 launch argument
/// `-UIPreferredContentSizeCategoryName`，走真實 Dynamic Type，不是 `.environment` 模擬。
extension TapTargetGateHarness {
    @MainActor
    @ViewBuilder
    static func uploadQueueEntryOrThumbnailCountHost(for screen: TapTargetGateScreenName) -> some View {
        if screen == .thumbnailCountStress { thumbnailCountStressHost } else { settingsUploadQueueEntryHost }
    }

    @MainActor
    static var thumbnailCountStressHost: some View {
        let environment = ProcessInfo.processInfo.environment
        return ThumbnailCountStressHost(
            fixture: environment["LS_THUMBNAIL_COUNT_FIXTURE"] ?? "import",
            remaining: environment["LS_THUMBNAIL_COUNT_REMAINING"].flatMap(Int.init) ?? 2
        )
        .preferredColorScheme(environment["LS_THUMBNAIL_COUNT_SCHEME"] == "dark" ? .dark : .light)
    }
}

private struct ThumbnailCountStressHost: View {
    let fixture: String
    let remaining: Int

    @State private var timelineStore = TimelineStore.preview()
    @State private var familyStore = FamilyStore.preview()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                Text("縮圖疊字壓測")
                    .appFont(.meta)
                    .foregroundStyle(Color.lsTextSecondary)
                if fixture == "diary" {
                    diaryCard
                } else {
                    ForEach([96.0, 64.0], id: \.self) { side in
                        HStack(alignment: .top, spacing: AppSpacing.item) {
                            ForEach([3, 28, 128], id: \.self) { count in
                                ImportMoreCell(count: count)
                                    .frame(width: side)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("thumbnailCount.cell.\(Int(side)).\(count)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .background(AppBackground())
    }

    private var diaryCard: some View {
        DiaryCardView(
            content: DiaryContent(
                body: "今天去公園玩。", entryDate: Date(),
                previewPhotos: (0..<3).map { _ in
                    MediaContent(
                        id: UUID(), type: .photo, width: 800, height: 600, thumbWidth: nil, thumbHeight: nil,
                        storagePath: "f/photo.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                    )
                },
                totalPhotoCount: 3 + remaining
            ),
            taggedChildren: [], timelineStore: timelineStore, familyStore: familyStore, refId: UUID(),
            previewRowWidth: UIScreen.main.bounds.width - 2 * AppSpacing.screenPad - 2 * AppSpacing.insetCard
        )
    }
}
#endif
