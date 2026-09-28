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
        NavigationStack(path: .constant([true])) {
            Color.clear
                .navigationTitle(foodRecordChildName)
                .navigationDestination(for: Bool.self) { _ in
                    FoodBookView(
                        previewStore: .previewSeededWithDemoRecords(apiClient: apiClient),
                        childName: foodRecordChildName, apiClient: apiClient
                    )
                }
        }
    }

    private static func foodRecordColorScheme(_ view: some View) -> some View {
        view.preferredColorScheme(UserDefaults.standard.bool(forKey: foodRecordDarkKey) ? .dark : nil)
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
            firstTriedOn: seeded.firstTriedOn, mediaID: photos.first?.id, note: "自己抓著吃，吃得滿臉都是麵包屑。",
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
#endif
