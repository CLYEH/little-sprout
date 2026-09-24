#if DEBUG
import SwiftUI

/// LS-365：時間軸照片卡寶貝署名（`PhotoCardSignature`）的 harness——`PhotoCardBabyCaptionUITests`
/// 量折行像素、截圖對 LS-367 規格板（`g57BHa` 淺／`u0yYg` 深／`ai2w5` AX3）。
///
/// 一次啟動只畫一張卡（`LS_PHOTO_CARD_CAPTION_FIXTURE` 選）：AX3 下四張照片卡疊起來遠超一屏，
/// 像素量測要求受測元件整個在畫面內，捲動定位不穩；一張卡置頂則一定看得到。
///
/// 年齡基準固定（`occurredAt` 2026-09-15 12:00 UTC、生日都在每月 1 日）——任何時區算出來的
/// 「今天」都落在 9/14–9/16，年齡字串不隨執行機時區漂移（小安「2 歲 3 個月」、小明／Emma Chen
/// 「8 個月大」、小饅頭「1 歲 8 個月」）。相簿卡（`AlbumSummaryCardView`）年齡以「現在」為準
/// （該檔文件註解），`.album` fixture 只量折行位置、不斷言年齡字串。
extension TapTargetGateHarness {
    enum PhotoCardCaptionFixture: String {
        case one, two, three, none, album, feed
    }

    static var photoCardCaptionFixture: PhotoCardCaptionFixture {
        ProcessInfo.processInfo.environment["LS_PHOTO_CARD_CAPTION_FIXTURE"]
            .flatMap(PhotoCardCaptionFixture.init(rawValue:)) ?? .one
    }

    /// `.feed` fixture 走真的 `TimelineView`（有標記＋未標記兩張照片卡），驗
    /// `TimelineView.cardView(for:columns:)` 把 `entry.childIds`／`occurredAt` 接進照片卡——
    /// 這個 fixture 沒有「照片卡署名」頂端標題（sentinel），測試直接等署名元素。
    @MainActor
    static var photoCardBabyCaptionHost: some View {
        PhotoCardBabyCaptionHost(fixture: photoCardCaptionFixture)
    }
}

/// 同 `InteractionRowHost` 的既有理由：store 放 `@State`，重繪不重新種子化。
private struct PhotoCardBabyCaptionHost: View {
    let fixture: TapTargetGateHarness.PhotoCardCaptionFixture

    private static let occurredAt = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    private static let mediaID = UUID()

    @State private var timelineStore = PhotoCardBabyCaptionHost.seededTimelineStore()
    @State private var childrenStore = PhotoCardBabyCaptionHost.seededChildrenStore()
    @State private var familyStore = FamilyStore.preview()

    var body: some View {
        switch fixture {
        case .feed:
            NavigationStack {
                TimelineView(
                    familyStore: familyStore, childrenStore: childrenStore, timelineStore: timelineStore,
                    diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
                    safetyAPIClient: PreviewSafetyAPIClient(), commentAPIClient: PreviewCommentAPIClient(),
                    albumsStore: .preview()
                )
            }
        case .album:
            singleCard {
                // `cardWidth` 只餵扇影比例縮放（`AlbumSummaryCardView` 文件註解），不影響署名折行；
                // 用 iPhone 基準卡寬即可。
                AlbumSummaryCardView(
                    album: AlbumSummary(
                        id: UUID(), title: "上禮拜的動物園一日遊", photoCount: 12, cover: nil,
                        childIds: [], createdAt: Date()
                    ),
                    // 相簿卡署名是 `$fs-meta`（AX3 約 33pt），「歐陽彥廷／Emma Chen · 2 歲 3 個月」在 iPhone 17 Pro
                    // 放得下一行、量不到折行位置；拉丁名＋一般空白才會真的折行。
                    taggedChildren: [Self.child("Charlotte Chen", born: "2024-06-01")],
                    cardWidth: 345
                )
                .accessibilityIdentifier("harness.albumCard")
            }
        case .one, .two, .three, .none:
            singleCard {
                PhotoCardView(
                    content: MediaContent(
                        id: Self.mediaID, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                        storagePath: "preview/photo.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                    ),
                    taggedChildren: Self.children(for: fixture), occurredAt: Self.occurredAt,
                    timelineStore: timelineStore, familyStore: familyStore
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("harness.photoCard")
            }
        }
    }

    private func singleCard(@ViewBuilder _ card: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                Text("照片卡署名")
                    .appFont(.meta)
                    .foregroundStyle(Color.lsTextSecondary)
                card()
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .background(AppBackground())
    }

    private static func children(for fixture: TapTargetGateHarness.PhotoCardCaptionFixture) -> [Child] {
        switch fixture {
        case .one: [child("小安", born: "2024-06-01")]
        case .two: [child("小安", born: "2024-06-01"), child("小明", born: "2026-01-01")]
        case .three:
            [child("歐陽彥廷", born: "2024-06-01"), child("小饅頭", born: "2025-01-01"),
             child("Emma Chen", born: "2026-01-01")]
        case .none, .album, .feed: []
        }
    }

    private static func child(_ name: String, born: String) -> Child {
        let birthday = ISO8601DateFormatter().date(from: "\(born)T00:00:00Z")!
        return Child(id: UUID(), name: name, birthday: birthday, avatarURL: nil, deletedAt: nil, createdAt: occurredAt)
    }

    private static let feedChild = child("小安", born: "2024-06-01")

    @MainActor
    private static func seededChildrenStore() -> ChildrenStore {
        let store = ChildrenStore.preview()
        store.seedForPreview(children: [feedChild])
        return store
    }

    /// `.feed` 用：有標記（小安）＋未標記各一張照片卡，同 LS-367 規格板 feed 摘錄（`Jh35i`）。
    @MainActor
    private static func seededTimelineStore() -> TimelineStore {
        let store = TimelineStore.preview()
        let taggedID = UUID()
        let untaggedID = UUID()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .media, refId: taggedID, occurredAt: occurredAt, childIds: [feedChild.id],
                content: .media(MediaContent(
                    id: taggedID, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "f/tagged.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ))
            ),
            TimelineEntry(
                kind: .media, refId: untaggedID, occurredAt: occurredAt.addingTimeInterval(-60), childIds: [],
                content: .media(MediaContent(
                    id: untaggedID, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                    storagePath: "f/untagged.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
                ))
            )
        ])
        return store
    }
}
#endif
