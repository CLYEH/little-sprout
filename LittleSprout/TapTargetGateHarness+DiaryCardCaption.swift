#if DEBUG
import SwiftUI

/// LS-374：時間軸日記卡署名（`MultiChildCaptionFormatter`，稿面 `cmp/Card Diary` `qtCd7`／多寶貝
/// `x7k2o6`）的 harness——`DiaryCardBabyCaptionUITests` 截圖矩陣（一位／兩位／三位 × xSmall／
/// 預設／AX3 × 淺／深）。
///
/// 一次啟動只畫一張卡：`LS_DIARY_CARD_CAPTION_FIXTURE` 選 one／two／three，
/// `LS_DIARY_CARD_CAPTION_SCHEME=dark` 用 `.preferredColorScheme(.dark)` 釘深色（同
/// `foodBookDarkHost` 既有做法，不依賴模擬器外觀設定）。年齡基準同 `PhotoCardBabyCaptionHost`：
/// `entryDate` 2026-09-15 12:00 UTC、生日都在每月 1 日，任何時區算出的年齡都相同。
extension TapTargetGateHarness {
    enum DiaryCardCaptionFixture: String {
        case one, two, three
    }

    @MainActor
    static var diaryCardBabyCaptionHost: some View {
        let environment = ProcessInfo.processInfo.environment
        let fixture = environment["LS_DIARY_CARD_CAPTION_FIXTURE"].flatMap(DiaryCardCaptionFixture.init(rawValue:))
        return DiaryCardBabyCaptionHost(fixture: fixture ?? .one)
            .preferredColorScheme(environment["LS_DIARY_CARD_CAPTION_SCHEME"] == "dark" ? .dark : .light)
    }
}

/// 同 `PhotoCardBabyCaptionHost` 的既有理由：store 放 `@State`，重繪不重新種子化。
private struct DiaryCardBabyCaptionHost: View {
    let fixture: TapTargetGateHarness.DiaryCardCaptionFixture

    private static let entryDate = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!

    @State private var timelineStore = TimelineStore.preview()
    @State private var familyStore = FamilyStore.preview()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.item) {
                Text("日記卡署名")
                    .appFont(.meta)
                    .foregroundStyle(Color.lsTextSecondary)
                DiaryCardView(
                    content: DiaryContent(
                        body: "今天在溜滑梯上玩得好開心，還交了一個新朋友。", entryDate: Self.entryDate,
                        previewPhotos: [], totalPhotoCount: 0
                    ),
                    taggedChildren: Self.children(for: fixture),
                    timelineStore: timelineStore, familyStore: familyStore, refId: UUID(),
                    previewRowWidth: UIScreen.main.bounds.width - 2 * AppSpacing.screenPad - 2 * AppSpacing.insetCard
                )
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .background(AppBackground())
    }

    private static func children(for fixture: TapTargetGateHarness.DiaryCardCaptionFixture) -> [Child] {
        switch fixture {
        case .one: [child("小安", born: "2024-06-01")]
        case .two: [child("小安", born: "2024-06-01"), child("小明", born: "2026-01-01")]
        case .three:
            [child("歐陽彥廷", born: "2024-06-01"), child("小饅頭", born: "2025-01-01"),
             child("Emma Chen", born: "2026-01-01")]
        }
    }

    private static func child(_ name: String, born: String) -> Child {
        let birthday = ISO8601DateFormatter().date(from: "\(born)T00:00:00Z")!
        return Child(id: UUID(), name: name, birthday: birthday, avatarURL: nil, deletedAt: nil, createdAt: entryDate)
    }
}
#endif
