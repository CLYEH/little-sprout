import Foundation
@testable import LittleSprout
import XCTest

/// LS-379 範圍 6：`food_catalog` 讀取＋`child_food_records` 依寶貝彙總（`FoodBookStore`）。
///
/// 鎖住的行為：
/// - 計數句分子只算目錄裡找得到的記錄（已下架食物的舊記錄不能讓「吃過 N」大於「全部 M」）。
/// - 每類「吃過 N／M」與格子順序（`sort_order`）。
/// - 目錄與記錄**一次換**：記錄讀取失敗時不能只換目錄——否則吃過的格子全變灰，看起來像資料被清掉。
/// - 讀取失敗保留上一份資料＋`.failure`（離線／42501 沿既有慣例顯示錯誤列）。
@MainActor
final class FoodBookStoreTests: XCTestCase {
    private final class StubFoodAPIClient: FoodAPIClient, @unchecked Sendable {
        var catalogResult: Result<[FoodCatalogItem], Error>
        var recordsResult: Result<[ChildFoodRecord], Error>
        private(set) var recordsRequestedFor: [UUID] = []

        init(catalog: [FoodCatalogItem], records: [ChildFoodRecord]) {
            catalogResult = .success(catalog)
            recordsResult = .success(records)
        }

        func listFoodCatalog() async throws -> [FoodCatalogItem] { try catalogResult.get() }

        func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
            recordsRequestedFor.append(childID)
            return try recordsResult.get()
        }
    }

    private static func item(_ id: String, _ category: FoodCategory, _ sortOrder: Int) -> FoodCatalogItem {
        FoodCatalogItem(id: id, nameZh: id, category: category, sortOrder: sortOrder, allergens: [], minAgeMonths: nil)
    }

    private let catalog = [
        item("white_rice", .grainRoot, 4), item("rice_cereal", .grainRoot, 1), item("pumpkin", .grainRoot, 9),
        item("yogurt", .dairy, 227), item("fresh_milk", .dairy, 226)
    ]

    func test_refresh_sortsCatalogBySortOrderAndCountsTriedPerCategory() async throws {
        let childID = UUID()
        let records = try [
            FoodBookCopyTests.record(foodID: "pumpkin", day: "2025-11-18"),
            FoodBookCopyTests.record(foodID: "yogurt", day: "2026-05-02")
        ]
        let client = StubFoodAPIClient(catalog: catalog, records: records)
        let store = FoodBookStore(childID: childID, apiClient: client)

        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(client.recordsRequestedFor, [childID], "記錄要依『這個』寶貝讀")
        XCTAssertEqual(
            store.items(in: .grainRoot).map(\.id), ["rice_cereal", "white_rice", "pumpkin"], "格子順序＝sort_order"
        )
        XCTAssertEqual(store.items(in: .dairy).map(\.id), ["fresh_milk", "yogurt"])
        XCTAssertEqual(store.totalCount, 5)
        XCTAssertEqual(store.triedCount, 2)
        XCTAssertEqual(store.triedCount(in: .grainRoot), 1)
        XCTAssertEqual(store.triedCount(in: .dairy), 1)
        XCTAssertEqual(store.triedCount(in: .fruit), 0)
        XCTAssertEqual(store.record(for: "pumpkin")?.foodID, "pumpkin")
        XCTAssertNil(store.record(for: "white_rice"))
    }

    /// 記錄指向目錄裡沒有的食物（`active = false` 下架）時不計入分子——「吃過 N 種，全部 M 種」的 N
    /// 必須等於畫面上看得到的紙片數。
    func test_triedCount_ignoresRecordsForFoodsNotInCatalog() async throws {
        let records = try [
            FoodBookCopyTests.record(foodID: "pumpkin", day: "2025-11-18"),
            FoodBookCopyTests.record(foodID: "retired_food", day: "2025-12-01")
        ]
        let store = FoodBookStore(childID: UUID(), apiClient: StubFoodAPIClient(catalog: catalog, records: records))

        await store.refresh()

        XCTAssertEqual(store.triedCount, 1)
    }

    func test_refresh_recordsFailure_keepsPreviousCatalogAndRecordsTogether() async throws {
        let records = try [FoodBookCopyTests.record(foodID: "pumpkin", day: "2025-11-18")]
        let client = StubFoodAPIClient(catalog: catalog, records: records)
        let store = FoodBookStore(childID: UUID(), apiClient: client)
        await store.refresh()

        client.catalogResult = .success(catalog + [Self.item("corn", .grainRoot, 12)])
        client.recordsResult = .failure(AppError.network(message: "offline"))
        let succeeded = await store.refresh()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.loadState, .failure(AppError.network(message: "offline")))
        XCTAssertEqual(store.totalCount, 5, "記錄失敗時目錄不能單獨換新（兩者一次換）")
        XCTAssertEqual(store.triedCount, 1, "上一份記錄要保留，吃過的格子不能變灰")
    }

    func test_refresh_firstLoadFailure_leavesEmptyCatalogAndFailureState() async {
        let client = StubFoodAPIClient(catalog: catalog, records: [])
        client.catalogResult = .failure(AppError.network(message: "offline"))
        let store = FoodBookStore(childID: UUID(), apiClient: client)

        await store.refresh()

        XCTAssertTrue(store.catalog.isEmpty)
        guard case .failure = store.loadState else {
            return XCTFail("首次載入失敗必須是 .failure（畫面走錯誤態＋重新載入），實際：\(store.loadState)")
        }
    }

    func test_needsRebuild_onlyWhenChildChanges() {
        let childID = UUID()
        let store = FoodBookStore(childID: childID, apiClient: StubFoodAPIClient(catalog: [], records: []))
        XCTAssertTrue(FoodBookStore.needsRebuild(current: nil, forChildID: childID))
        XCTAssertFalse(FoodBookStore.needsRebuild(current: store, forChildID: childID))
        XCTAssertTrue(FoodBookStore.needsRebuild(current: store, forChildID: UUID()))
    }

    /// 示範資料集（harness 截圖對稿用）必須對上 Notes `UsJkk`：38／274、穀物根莖 10／16、乳製品 1／7。
    func test_previewDemoStore_matchesDesignDemoNumbers() {
        let store = FoodBookStore.previewSeededWithDemoRecords()
        XCTAssertEqual(store.totalCount, 274)
        XCTAssertEqual(store.triedCount, 38)
        XCTAssertEqual(store.triedCount(in: .grainRoot), 10)
        XCTAssertEqual(store.items(in: .grainRoot).count, 16)
        XCTAssertEqual(store.triedCount(in: .dairy), 1)
        XCTAssertEqual(store.items(in: .dairy).count, 7)
    }
}
