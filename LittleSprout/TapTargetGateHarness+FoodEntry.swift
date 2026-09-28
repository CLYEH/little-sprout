#if DEBUG
import SwiftUI

/// LS-382：寶貝詳情「飲食圖鑑」入口（01 家族）的 harness host——同 `TapTargetGateHarness+Food.swift` 的拆檔先例。
/// 不能標 `private`（`TapTargetGateHarness.hostView(for:)` 跨檔案存取不到）。
///
/// 宿主是真的 `ChildGrowthDetailView`（成長區塊用示範資料），飲食圖鑑 client 經 `\.foodAPIClient` 注入——入口的
/// store 走正式的 `.task(id:)` 讀取路徑，不是預先種好的。四個 fixture：
/// - `.growthDetailFood`（01 `QRoGt`）：示範 38／274；最近五筆＝香蕉 8/2、豆腐 7/19、蛋黃 7/5、吐司麵包 6/8、優格 5/2
///   （逐格照稿 `DtcpY`／01-iPad `i6WGR`）。
/// - `.growthDetailFoodEmpty`（01b `J58vyP`）：0 筆，三格＝`sort_order` 前三。
/// - `.growthDetailFoodOne`（01c `ls2g6`）：只記米精 1 筆，後兩格依 `sort_order` 補未吃。
/// - `.growthDetailFoodFailure`：讀取一律斷線（Notes 01 列「失敗文案鍵 42501」的錯誤態）。
///
/// 深色：launch argument `-LSFoodEntryDark YES`（同 `foodRecordDarkKey` 手法，不另開 case）。
extension TapTargetGateHarness {
    static let foodEntryDarkKey = "LSFoodEntryDark"

    @MainActor
    @ViewBuilder
    static func foodEntryHost(for screen: TapTargetGateScreenName) -> some View {
        switch screen {
        case .growthDetailFood: FoodEntryHarnessHost(fixture: .demo)
        case .growthDetailFoodEmpty: FoodEntryHarnessHost(fixture: .empty)
        case .growthDetailFoodOne: FoodEntryHarnessHost(fixture: .one)
        case .growthDetailFoodFailure: FoodEntryHarnessHost(fixture: .failure)
        default: EmptyView()
        }
    }
}

/// store／client 放 `@State`、只建一次（同 `FoodRecordBookHarnessHost` 的理由：重繪換出新 client 會讓寫入落到別顆）。
private struct FoodEntryHarnessHost: View {
    enum Fixture {
        case demo, empty, one, failure
    }

    @State private var growthStore: GrowthStore
    @State private var apiClient: PreviewFoodAPIClient

    init(fixture: Fixture) {
        let growthStore = GrowthStore.previewSeededWithDemoRecords()
        let childID = growthStore.childID
        let apiClient: PreviewFoodAPIClient = switch fixture {
        case .demo: PreviewFoodAPIClient(records: FoodBookStore.entryDemoRecords(childID: childID))
        case .empty: PreviewFoodAPIClient()
        case .one: PreviewFoodAPIClient(records: [FoodBookStore.entryRecord("rice_cereal", "2025-10-22", childID)])
        case .failure: PreviewFoodAPIClient(listFailure: .network(message: "harness：斷線"))
        }
        _growthStore = State(initialValue: growthStore)
        _apiClient = State(initialValue: apiClient)
    }

    var body: some View {
        NavigationStack {
            ChildGrowthDetailView(
                previewGrowthStore: growthStore, currentUserID: GrowthStore.previewAuthorID, isFamilyOwner: true
            )
        }
        .environment(\.foodAPIClient, apiClient)
        .preferredColorScheme(UserDefaults.standard.bool(forKey: TapTargetGateHarness.foodEntryDarkKey) ? .dark : nil)
    }
}

extension FoodBookStore {
    /// 01 示範資料：沿 `demoRecords`（38 筆、各類筆數照 Notes `UsJkk`），只把「最近」幾筆的日期對到稿面——香蕉 8/2、
    /// 豆腐 7/19（取代肉魚蛋豆補位的雞胸肉，類別筆數不變）、蛋黃 7/5；其餘補位日期挪到 4/15（早於優格 5/2），
    /// iPad 五格才會是稿面的香蕉／豆腐／蛋黃／吐司麵包／優格。
    static func entryDemoRecords(childID: UUID) -> [ChildFoodRecord] {
        let pinned = ["banana": "2026-08-02", "tofu": "2026-07-19", "egg_yolk": "2026-07-05"]
        let fillerDate = BirthdayFormat.date(fromWireString: "2026-07-15")
        return demoRecords(childID: childID).map { record in
            let foodID = record.foodID == "chicken_breast" ? "tofu" : record.foodID
            if let day = pinned[foodID] { return entryRecord(foodID, day, childID) }
            if record.firstTriedOn == fillerDate { return entryRecord(foodID, "2026-04-15", childID) }
            return record
        }
    }

    static func entryRecord(_ foodID: String, _ day: String, _ childID: UUID) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: day)!
        return ChildFoodRecord(
            id: UUID(), familyID: UUID(), childID: childID, foodID: foodID, authorID: nil, firstTriedOn: date,
            mediaID: nil, note: nil, reaction: nil, createdAt: date, updatedAt: date
        )
    }
}
#endif
