#if DEBUG
import SwiftUI

/// LS-380：第一次記錄 sheet 家族（03／03b／03c／03d／03e）的 harness host——同 `TapTargetGateHarness+Food.swift`
/// 的拆檔先例。不能標 `private`（`TapTargetGateHarness.hostView(for:)` 跨檔案存取不到）。
///
/// 三個 host 都把 sheet 疊在真的 `FoodBookView` 之上（稿面 Scrim 後面是呼叫端畫面；03c 背景＝呼叫端當下畫面）：
/// - `.foodRecordSheet`：圖鑑本身，UITest 點「芋頭」空位開 03、再點「從家庭相簿挑」開 03d；儲存會成功，
///   sheet 收起後播 06「收下」動效。
/// - `.foodRecordSheetFailure`：同上但 upsert 一律斷線（03e）。
/// - `.foodRecordSheetEdit`：一開就疊著 03b（吐司麵包，有照片、反應「喜歡」、有一句話）；點「刪除這筆記錄」開 03c。
///
/// 深色：launch argument `-LSFoodRecordDark YES`（同一個 case 淺深各跑一次，不另開 enum case）。示範孩子名
/// 「小安」＝稿面文案（Notes `UsJkk` 示範資料的暱稱）。
extension TapTargetGateHarness {
    static let foodRecordDarkKey = "LSFoodRecordDark"
    /// `.foodRecordSheetEdit`：原照片讀不到（`media_id` 指向不存在的照片，R1 i4）。
    static let foodRecordMissingPhotoKey = "LSFoodRecordMissingPhoto"
    /// `.foodRecordDetailFlow`：南瓜那筆已在後端被刪（圖鑑還以為吃過），開詳情即發現（接縫④）。
    static let foodRecordFlowGoneKey = "LSFoodRecordFlowGone"
    static let foodRecordChildName = "小安"

    /// 飲食圖鑑家族（LS-379 02 × 4＋LS-380 03 × 3）的 dispatch——從 `hostView(for:)` 搬來（該 enum 逼近
    /// SwiftLint `type_body_length` 上限，七個 case 在那邊併成一行轉呼叫這裡）。
    @MainActor
    @ViewBuilder
    static func foodHost(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .foodBook: foodBookHost
        case .foodBookDark: foodBookDarkHost
        case .foodBookDairy: foodBookDairyHost
        case .foodBookViewer: foodBookViewerHost
        case .foodRecordSheet: foodRecordSheetHost
        case .foodRecordSheetFailure: foodRecordSheetFailureHost
        case .foodRecordSheetEdit: foodRecordSheetEditHost
        case .foodRecordDetailFlow: foodRecordColorScheme(FoodRecordDetailFlowHarnessHost())
        case .foodRecordDetailServer: FoodRecordDetailServerHarnessHost()
        default: EmptyView()
        }
    }

    @MainActor
    @ViewBuilder
    static var foodRecordSheetHost: some View {
        foodRecordColorScheme(foodRecordBook(apiClient: PreviewFoodAPIClient(photos: FamilyPhoto.previewSamples())))
    }

    @MainActor
    @ViewBuilder
    static var foodRecordSheetFailureHost: some View {
        foodRecordColorScheme(foodRecordBook(apiClient: PreviewFoodAPIClient(
            upsertFailure: .network(message: "harness：斷線"), photos: FamilyPhoto.previewSamples()
        )))
    }

    @MainActor
    @ViewBuilder
    static var foodRecordSheetEditHost: some View {
        foodRecordColorScheme(FoodRecordEditHarnessHost())
    }

    @MainActor
    private static func foodRecordBook(apiClient: PreviewFoodAPIClient) -> some View {
        FoodRecordBookHarnessHost(apiClient: apiClient)
    }

    private static func foodRecordColorScheme(_ view: some View) -> some View {
        view.preferredColorScheme(UserDefaults.standard.bool(forKey: foodRecordDarkKey) ? .dark : nil)
    }
}

/// 03／03d／03e：圖鑑本身。store 放在 `@State`、只建一次——在 `navigationDestination` 閉包裡現建的話，sheet
/// 開關造成閉包重跑會換出一顆新 store（新的隨機孩子 id），`FoodBookView` 的 `.task(id: child.id)` 以為換了寶貝
/// 就重讀（假 client 回 0 筆），儲存後的計數對不上（實測：38 → 1）。
private struct FoodRecordBookHarnessHost: View {
    @State private var store: FoodBookStore
    private let apiClient: PreviewFoodAPIClient

    init(apiClient: PreviewFoodAPIClient) {
        self.apiClient = apiClient
        _store = State(initialValue: FoodBookStore.previewSeededWithDemoRecords(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle(TapTargetGateHarness.foodRecordChildName)
                .navigationDestination(for: Bool.self) { _ in
                    FoodBookView(
                        previewStore: store, childName: TapTargetGateHarness.foodRecordChildName, apiClient: apiClient
                    )
                }
        }
    }
}

/// 03b／03c：圖鑑＋一開就疊著的編輯 sheet（吐司麵包，稿 `ekxHM` 的示範內容）。刪除成功後那一格退回「還沒吃」
/// ——`FoodRecordSheetUITests.testDeleteReturnsCellToUntried` 驗。
private struct FoodRecordEditHarnessHost: View {
    @State private var store: FoodBookStore
    @State private var editing: ChildFoodRecord?
    private let apiClient: PreviewFoodAPIClient
    private let bread: FoodCatalogItem

    init() {
        let photos = FamilyPhoto.previewSamples()
        let apiClient = PreviewFoodAPIClient(photos: photos)
        let store = FoodBookStore.previewSeededWithDemoRecords(apiClient: apiClient)
        let bread = PreviewFoodCatalog.items.first { $0.id == "bread" }!
        let seeded = store.record(for: "bread")!
        let record = ChildFoodRecord(
            id: seeded.id, familyID: seeded.familyID, childID: store.childID, foodID: "bread", authorID: nil,
            firstTriedOn: seeded.firstTriedOn,
            mediaID: UserDefaults.standard.bool(forKey: TapTargetGateHarness.foodRecordMissingPhotoKey)
                ? UUID() : photos.first?.id,
            note: "自己抓著吃，吃得滿臉都是麵包屑。",
            reaction: FoodReaction.liked.rawValue, createdAt: seeded.createdAt, updatedAt: seeded.updatedAt
        )
        store.applySaved(record)
        self.apiClient = apiClient
        self.bread = bread
        _store = State(initialValue: store)
        _editing = State(initialValue: record)
    }

    var body: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle(TapTargetGateHarness.foodRecordChildName)
                .navigationDestination(for: Bool.self) { _ in
                    FoodBookView(
                        previewStore: store, childName: TapTargetGateHarness.foodRecordChildName, apiClient: apiClient
                    )
                }
        }
        .sheet(item: $editing) { record in
            FoodRecordSheet(
                childName: TapTargetGateHarness.foodRecordChildName,
                store: FoodRecordEditorStore(
                    childID: store.childID, item: bread, editingRecord: record, apiClient: apiClient
                ),
                apiClient: apiClient,
                onSaved: { store.applySaved($0) },
                onDeleted: { store.removeRecord(id: $0) }
            )
        }
    }
}
/// LS-380 R2 接縫①④⑥⑦：圖鑑（帶 `recordDetailContext`）→ 吃過的格子 → 04 詳情 → 03b／03c／04b 加照片。
/// 登入者＝媽媽（owner）：吐司麵包、南瓜（沒照片）是媽媽記的（作者：只有「編輯」）；米精是爸爸記的（04c：只有
/// 「刪除」）。假 client 有狀態（upsert／delete 會改清單），詳情頁重讀拿得到剛存的值。
private struct FoodRecordDetailFlowHarnessHost: View {
    @State private var store: FoodBookStore
    private let apiClient: PreviewFoodAPIClient
    private static let mom = UUID()
    private static let dad = UUID()

    init() {
        let photos = FamilyPhoto.previewSamples()
        let seeded = FoodBookStore.previewSeededWithDemoRecords()
        func record(_ foodID: String, author: UUID, mediaID: UUID?) -> ChildFoodRecord {
            let old = seeded.record(for: foodID)!
            return ChildFoodRecord(
                id: old.id, familyID: old.familyID, childID: seeded.childID, foodID: foodID, authorID: author,
                firstTriedOn: old.firstTriedOn, mediaID: mediaID, note: "自己抓著吃。", reaction: "liked",
                createdAt: old.createdAt, updatedAt: old.updatedAt
            )
        }
        let mom = Self.mom, dad = Self.dad
        let bread = record("bread", author: mom, mediaID: photos.first?.id)
        let pumpkin = record("pumpkin", author: mom, mediaID: nil)
        let riceCereal = record("rice_cereal", author: dad, mediaID: photos.first?.id)
        let pumpkinIsGone = UserDefaults.standard.bool(forKey: TapTargetGateHarness.foodRecordFlowGoneKey)
        let apiClient = PreviewFoodAPIClient(
            records: pumpkinIsGone ? [bread, riceCereal] : [bread, pumpkin, riceCereal], photos: photos,
            currentUserID: mom
        )
        let store = FoodBookStore.previewSeededWithDemoRecords(childID: seeded.childID, apiClient: apiClient)
        [bread, pumpkin, riceCereal].forEach(store.applySaved)
        self.apiClient = apiClient
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle(TapTargetGateHarness.foodRecordChildName)
                .navigationDestination(for: Bool.self) { _ in
                    FoodBookView(
                        previewStore: store, childName: TapTargetGateHarness.foodRecordChildName, apiClient: apiClient,
                        recordDetailContext: FoodRecordDetailContext(currentUserID: Self.mom, isFamilyOwner: true)
                    )
                }
        }
        .environment(
            \.foodRecordDetailAPIClient, PreviewFoodRecordDetailAPIClient(names: [Self.mom: "媽媽", Self.dad: "爸爸"])
        )
    }
}
/// LS-380 R3（QA `a27eafaf`）：真入口的條件——呼叫端給詳情頁的那一筆**推入後就不再更新**（圖鑑的
/// `navigationDestination` 閉包在真導覽下不隨 store 重跑，實機 log 見 R3 handoff）、API 回的是伺服器那一列
/// （`ServerShapedFoodAPIClient`）。`onSaved`／`onRemoved` 刻意什麼都不做：詳情頁得靠 router 自己換新。
private struct FoodRecordDetailServerHarnessHost: View {
    private static let mom = UUID()
    private static let child = Child(
        id: UUID(), name: TapTargetGateHarness.foodRecordChildName,
        birthday: BirthdayFormat.date(fromWireString: "2025-04-20")!, avatarURL: nil, deletedAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_750_000_000)
    )
    private static let serverTime = Date(timeIntervalSince1970: 1_780_000_000)
    private static let frozenRecord = ChildFoodRecord(
        id: UUID(), familyID: UUID(), childID: child.id, foodID: "bread", authorID: mom,
        firstTriedOn: BirthdayFormat.date(fromWireString: "2026-06-08")!, mediaID: nil, note: "自己抓著吃。",
        reaction: FoodReaction.liked.rawValue, createdAt: serverTime, updatedAt: serverTime
    )
    private static let apiClient = ServerShapedFoodAPIClient(rows: [frozenRecord], serverClock: serverTime)

    var body: some View {
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle("飲食圖鑑")
                .navigationDestination(for: Bool.self) { _ in
                    FoodRecordDetailRouter(
                        child: Self.child, item: PreviewFoodCatalog.items.first { $0.id == "bread" }!,
                        record: Self.frozenRecord, apiClient: Self.apiClient,
                        context: FoodRecordDetailContext(currentUserID: Self.mom, isFamilyOwner: true), canRecord: true,
                        onSaved: { _ in }, onRemoved: { _ in }
                    )
                }
        }
    }
}
#endif
