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
/// - `paper`（LS-446）：照片卡＋食物卡＋已按讚日記卡（附照三張、第三張疊「還有 N 張」）＋未按讚日記卡並列，
///   給 `DiaryCardPaperScreenshotUITests` 對稿面 `Qohx3`（日記卡改整張紙面）截淺／深／AX3。
///
/// `LS_FOOD_FIRST_SCHEME=dark` 釘深色（同 `diaryCardBabyCaptionHost`）。照片用 `PreviewFoodRecordDetailAPIClient`
/// 同一張本機佔位照（稿面示範照本來就是佔位，Design Note `r7slt2`）。`\.foodAPIClient` 注入 `PreviewFoodAPIClient`（完整 274 種
/// 目錄＋這幾筆記錄），兩個目的地才推得進去。
extension TapTargetGateHarness {
    enum FoodFirstCardFixture: String {
        case spec, dairy, paper
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
        let foodAPIClient = PreviewFoodAPIClient(
            records: FoodFirstCardSample.records(fixture), currentUserID: FoodFirstCardSample.mom
        )
        _timelineStore = State(initialValue: FoodFirstCardSample.timelineStore(fixture, foodAPIClient: foodAPIClient))
        _foodAPIClient = State(initialValue: foodAPIClient)
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

    /// 記錄固定成 `static let`：時間軸（`timelineStore`）與假 client（`foodAPIClient`）各自呼叫 `records(_:)`，
    /// id 若每次重建兩邊就不是同一筆——`.foodRecordDetail` 帶的快照在詳情頁重讀時查不到，會當成已被刪而返回
    /// （`FoodRecordDetailStore.isGone`）。
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
        case .paper: [bread]
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
    static func timelineStore(
        _ fixture: TapTargetGateHarness.FoodFirstCardFixture, foodAPIClient: PreviewFoodAPIClient
    ) -> TimelineStore {
        let store = TimelineStore(apiClient: FoodFirstCardTimelineAPIClient(foodAPIClient: foodAPIClient))
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
        if fixture == .paper {
            entries = paperEntries(foodEntry: entries[0], store: store)
        }
        store.seedForPreview(entries: entries, familyID: familyID)
        return store
    }

    /// LS-446：`paper` 固定版——照片卡（最新）→ 已按讚日記卡（附照）→ 未按讚日記卡 → 食物卡。反應種子與卡片同時種進 `store`。
    @MainActor
    private static func paperEntries(foodEntry: TimelineEntry, store: TimelineStore) -> [TimelineEntry] {
        func photo(_ id: UUID = UUID()) -> MediaContent {
            MediaContent(
                id: id, type: .photo, width: 4, height: 3, thumbWidth: nil, thumbHeight: nil,
                storagePath: "preview/paper.jpg", isThumbnail: true,
                signedURL: PreviewFoodRecordDetailAPIClient.samplePhotoURL, durationSeconds: nil
            )
        }
        let day = BirthdayFormat.date(fromWireString: "2026-08-22")!
        let dayBefore = BirthdayFormat.date(fromWireString: "2026-08-21")!
        let mediaID = UUID()
        let likedDiaryID = UUID()
        let idleDiaryID = UUID()
        store.seedReactionState(
            ReactionState(count: 2, reactedByMe: false), forKey: TimelineEntry.id(kind: .media, refId: mediaID)
        )
        store.seedReactionState(
            ReactionState(count: 4, reactedByMe: true), forKey: TimelineEntry.id(kind: .diary, refId: likedDiaryID)
        )
        store.seedReactionState(
            ReactionState(count: 1, reactedByMe: false), forKey: TimelineEntry.id(kind: .diary, refId: idleDiaryID)
        )
        return [
            TimelineEntry(
                kind: .media, refId: mediaID, occurredAt: day, childIds: [child.id], content: .media(photo(mediaID))
            ),
            TimelineEntry(
                kind: .diary, refId: likedDiaryID, occurredAt: dayBefore, childIds: [child.id],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心，還交了一個新朋友，說好下次要一起帶挖沙工具來。", entryDate: dayBefore,
                    previewPhotos: [photo(), photo(), photo()], totalPhotoCount: 5
                ))
            ),
            TimelineEntry(
                kind: .diary, refId: idleDiaryID, occurredAt: dayBefore, childIds: [child.id],
                content: .diary(DiaryContent(
                    body: "午睡醒來自己坐在床上玩了好久。", entryDate: dayBefore, previewPhotos: [], totalPhotoCount: 0
                ))
            ),
            foodEntry
        ]
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

/// LS-393（merge-review LS-383 R3 i8）：時間軸重讀時回「假 client 目前的記錄」，存檔後的強制重讀
/// （`TimelineView.refreshAfterFoodRecordChange`）才看得出效果——回到時間軸，卡片換成剛存的值。
/// 只重建食物卡：第一頁＝每筆記錄一個 `food_first` 指標（依第一次吃的日期新到舊），之後的頁一律空；
/// 同日日記卡、照片縮圖重讀後不會回來（沒有測試在重讀之後看它們）。
private final class FoodFirstCardTimelineAPIClient: TimelineAPIClient, @unchecked Sendable {
    private let foodAPIClient: PreviewFoodAPIClient

    init(foodAPIClient: PreviewFoodAPIClient) {
        self.foodAPIClient = foodAPIClient
    }

    func fetchTimelinePointers(
        familyID: UUID, childID: UUID?, cursor: TimelineCursor?, limit: Int
    ) async throws -> [TimelineFeedPointer] {
        guard cursor == nil else { return [] }
        return try await records()
            .sorted { $0.firstTriedOn > $1.firstTriedOn }
            .map {
                TimelineFeedPointer(kind: .foodFirst, refId: $0.id, occurredAt: $0.firstTriedOn, childIds: [$0.childID])
            }
    }

    func fetchFoodRecords(ids: [UUID]) async throws -> [ChildFoodRecord] {
        try await records().filter { ids.contains($0.id) }
    }

    private func records() async throws -> [ChildFoodRecord] {
        try await foodAPIClient.listChildFoodRecords(childID: FoodFirstCardSample.child.id)
    }

    func fetchFoodCatalogItems(ids: [String]) async throws -> [FoodCatalogItem] {
        PreviewFoodCatalog.items.filter { ids.contains($0.id) }
    }

    func fetchDiaries(ids: [UUID]) async throws -> [DiaryRow] { [] }
    func fetchDiaryMediaLinks(diaryIds: [UUID]) async throws -> [DiaryMediaLinkRow] { [] }
    func fetchAlbums(ids: [UUID]) async throws -> [AlbumRow] { [] }
    func fetchMedia(ids: [UUID]) async throws -> [MediaRow] { [] }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }
    func reactionCounts(familyID: UUID, targetType: String, targetIDs: [UUID]) async throws -> [ReactionCountRow] { [] }
    func toggleReaction(familyID: UUID, targetType: String, targetID: UUID) async throws -> Bool { true }
    func reactors(familyID: UUID, targetType: String, targetID: UUID) async throws -> [ReactorRow] { [] }
}
#endif
