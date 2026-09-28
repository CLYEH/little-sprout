#if DEBUG
import SwiftUI

/// LS-383：時間軸「第一次吃到〇〇」卡片（`FoodFirstCardView`，稿 05 `SLjde`／深色 `QGdHY`／AX3 `CgmBD`）的 harness——
/// 走**真的 `TimelineView`**（卡片分派、Day Divider 分組、兩個 `TimelineRoute` 目的地都是正式程式碼），供
/// `FoodFirstCardUITests`（Book Row 導向、整卡開詳情、無互動列、截圖矩陣）與 `TapTargetGateTests` 用。
///
/// `LS_FOOD_FIRST_FIXTURE`：
/// - `spec`（預設）：稿面四態，示範資料沿 Notes `UsJkk`（小安，出生 2025-04-20）——
///   芋頭 2026/8/20 普通＋一句話，與同日日記並列（Feed Excerpt `owgBO`）；吐司麵包 2026/5/20 喜歡＋一句話＋照片
///   （`Sln4U`，1 歲 1 個月）；玉米 2026/2/20 只有日期（`A5xBK`，10 個月大）；南瓜 2025/10/20 喜歡＋一句話、沒照片
///   （`XYZJ5`，6 個月大）。
/// - `dairy`：只有一張優格卡（乳製品）——穀物根莖是圖鑑預設第一類，Book Row 導向測試要用別類才驗得出「選到該類」。
///
/// `LS_FOOD_FIRST_SCHEME=dark` 釘深色（同 `diaryCardBabyCaptionHost`）。照片用 `PreviewFoodRecordDetailAPIClient`
/// 同一張本機佔位照（稿面示範照本來就是佔位，Design Note `r7slt2`）。`\.foodAPIClient` 注入 `PreviewFoodAPIClient`（完整 274 種
/// 目錄＋這幾筆記錄），兩個目的地才推得進去。
extension TapTargetGateHarness {
    enum FoodFirstCardFixture: String {
        case spec, dairy
    }

    @MainActor
    static var foodFirstCardHost: some View {
        let environment = ProcessInfo.processInfo.environment
        let fixture = environment["LS_FOOD_FIRST_FIXTURE"].flatMap(FoodFirstCardFixture.init(rawValue:)) ?? .spec
        return FoodFirstCardHost(fixture: fixture)
            .preferredColorScheme(environment["LS_FOOD_FIRST_SCHEME"] == "dark" ? .dark : .light)
    }
}

/// store 放 `@State`，重繪不重新種子化（同 `PhotoCardBabyCaptionHost`）。
private struct FoodFirstCardHost: View {
    let fixture: TapTargetGateHarness.FoodFirstCardFixture

    @State private var timelineStore: TimelineStore
    @State private var childrenStore = FoodFirstCardSample.childrenStore()
    @State private var familyStore = FoodFirstCardSample.familyStore()
    /// 有狀態的假 client（R2）：放 `@State` 才不會每次重繪換一份新的、把 03b 剛存的值洗回去。
    @State private var foodAPIClient: PreviewFoodAPIClient

    init(fixture: TapTargetGateHarness.FoodFirstCardFixture) {
        self.fixture = fixture
        _timelineStore = State(initialValue: FoodFirstCardSample.timelineStore(fixture))
        _foodAPIClient = State(initialValue: PreviewFoodAPIClient(
            records: FoodFirstCardSample.records(fixture), currentUserID: FoodFirstCardSample.mom
        ))
    }

    var body: some View {
        NavigationStack {
            TimelineView(
                familyStore: familyStore, childrenStore: childrenStore, timelineStore: timelineStore,
                diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService(),
                safetyAPIClient: PreviewSafetyAPIClient(), commentAPIClient: PreviewCommentAPIClient(),
                albumsStore: .preview()
            )
        }
        .environment(\.foodAPIClient, foodAPIClient)
        .environment(\.foodRecordDetailAPIClient, PreviewFoodRecordDetailAPIClient(names: [:]))
    }
}

private enum FoodFirstCardSample {
    static let child = Child(
        id: UUID(), name: "小安", birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!,
        avatarURL: nil, deletedAt: nil, createdAt: Date()
    )
    static let familyID = UUID()
    static let diaryID = UUID()
    /// 登入者＝媽媽（owner），harness 的記錄都是她記的——詳情頁看得到「編輯這筆記錄」（R2 接縫 hook 測試用）。
    static let mom = UUID()

    /// 記錄固定成 `static let`：id 若每次重建，`TimelineRoute` 從 `entries` 查不到同一筆。
    static let taro = record("taro", "2026-08-20", reaction: "neutral", note: "有點黏，吃了三口就搖頭。")
    static let bread = record(
        "bread", "2026-05-20", reaction: "liked", note: "自己抓著吃，吃得滿臉都是麵包屑。", mediaID: UUID()
    )
    static let corn = record("corn", "2026-02-20", reaction: nil, note: nil)
    static let pumpkin = record("pumpkin", "2025-10-20", reaction: "liked", note: "一口接一口，把整碗吃光了。")
    static let yogurt = record("yogurt", "2026-05-02", reaction: "liked", note: "酸酸的，皺了一下眉頭又張嘴。")

    static func records(_ fixture: TapTargetGateHarness.FoodFirstCardFixture) -> [ChildFoodRecord] {
        switch fixture {
        case .spec: [taro, bread, corn, pumpkin]
        case .dairy: [yogurt]
        }
    }

    @MainActor
    static func childrenStore() -> ChildrenStore {
        let store = ChildrenStore.preview()
        store.seedForPreview(children: [child])
        store.seedRoleForPreview(.owner)
        return store
    }

    /// 只種登入者、不種 `myFamily`：`myFamily` 非 nil 會讓 `TimelineView` 的 `.task` 重新整理、洗掉種好的卡片。
    @MainActor
    static func familyStore() -> FamilyStore {
        let store = FamilyStore.preview()
        store.seedOwnerUserIDForPreview(mom)
        return store
    }

    @MainActor
    static func timelineStore(_ fixture: TapTargetGateHarness.FoodFirstCardFixture) -> TimelineStore {
        let store = TimelineStore.preview()
        var entries = records(fixture).map(entry)
        if fixture == .spec {
            // 同日並列：芋頭之後接一張同一天的日記卡（稿 Feed Excerpt `qILb9`）。
            let day = taro.firstTriedOn
            entries.insert(
                TimelineEntry(
                    kind: .diary, refId: diaryID, occurredAt: day, childIds: [child.id],
                    content: .diary(DiaryContent(
                        body: "今天在溜滑梯上玩得好開心，還交了一個新朋友。", entryDate: day,
                        previewPhotos: [], totalPhotoCount: 0
                    ))
                ),
                at: 1
            )
        }
        store.seedForPreview(entries: entries, familyID: familyID)
        return store
    }

    private static func entry(_ record: ChildFoodRecord) -> TimelineEntry {
        let item = PreviewFoodCatalog.items.first { $0.id == record.foodID }!
        let photo = record.mediaID.map {
            MediaContent(
                id: $0, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/food.jpg", isThumbnail: true,
                signedURL: PreviewFoodRecordDetailAPIClient.samplePhotoURL, durationSeconds: nil
            )
        }
        return TimelineEntry(
            kind: .foodFirst, refId: record.id, occurredAt: record.firstTriedOn, childIds: [record.childID],
            content: .foodFirst(FoodFirstContent(record: record, item: item, photo: photo))
        )
    }

    private static func record(
        _ foodID: String, _ day: String, reaction: String?, note: String?, mediaID: UUID? = nil
    ) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: day)!
        return ChildFoodRecord(
            id: UUID(), familyID: familyID, childID: child.id, foodID: foodID, authorID: mom, firstTriedOn: date,
            mediaID: mediaID, note: note, reaction: reaction, createdAt: date, updatedAt: date
        )
    }
}
#endif
