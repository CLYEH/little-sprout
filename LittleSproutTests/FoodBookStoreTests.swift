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

        // LS-380 的寫入／照片方法：`FoodBookStore` 不呼叫它們，被呼叫到就是測試寫錯，大聲失敗。
        func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord { throw Unused() }
        func deleteChildFoodRecord(id: UUID) async throws { throw Unused() }
        func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { throw Unused() }
        func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { throw Unused() }
        func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { throw Unused() }
        func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
            throw Unused()
        }
    }

    private struct Unused: Error {}

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

    // MARK: - LS-380：sheet 儲存／刪除後就地更新

    private static func record(_ foodID: String, childID: UUID, id: UUID = UUID()) -> ChildFoodRecord {
        let date = BirthdayFormat.date(fromWireString: "2026-08-20")!
        return ChildFoodRecord(
            id: id, familyID: UUID(), childID: childID, foodID: foodID, authorID: nil, firstTriedOn: date,
            mediaID: nil, note: nil, reaction: nil, createdAt: date, updatedAt: date
        )
    }

    /// 儲存成功 → 那一格變吃過、計數＋1；同一食物再存（03b 編輯）是替換不是多一筆。
    func test_applySaved_addsThenReplacesSameFood() async {
        let childID = UUID()
        let store = FoodBookStore(childID: childID, apiClient: StubFoodAPIClient(catalog: catalog, records: []))
        await store.refresh()

        store.applySaved(Self.record("pumpkin", childID: childID))
        XCTAssertEqual(store.triedCount, 1)
        XCTAssertEqual(FoodCellState.make(record: store.record(for: "pumpkin"), canRecord: true).isTried, true)

        let edited = Self.record("pumpkin", childID: childID)
        store.applySaved(edited)
        XCTAssertEqual(store.triedCount, 1, "同一食物再存是替換（partial unique index：每寶貝每食物最多一筆）")
        XCTAssertEqual(store.record(for: "pumpkin")?.id, edited.id)
        XCTAssertEqual(store.records.count, 1)
    }

    /// 儲存途中換了寶貝（store 已是別的孩子）：回傳列不能塞進這本圖鑑。
    func test_applySaved_ignoresRecordOfAnotherChild() async {
        let store = FoodBookStore(childID: UUID(), apiClient: StubFoodAPIClient(catalog: catalog, records: []))
        await store.refresh()

        store.applySaved(Self.record("pumpkin", childID: UUID()))

        XCTAssertEqual(store.triedCount, 0)
        XCTAssertNil(store.record(for: "pumpkin"))
    }

    /// 票文驗收「刪除→格子回未吃」：刪掉的那一格退回灰色空位（`.untried`）、計數同步減一，其他格不動。
    func test_removeRecord_returnsCellToUntriedAndDecrementsCount() async {
        let childID = UUID()
        let pumpkin = Self.record("pumpkin", childID: childID)
        let yogurt = Self.record("yogurt", childID: childID)
        let store = FoodBookStore(
            childID: childID, apiClient: StubFoodAPIClient(catalog: catalog, records: [pumpkin, yogurt])
        )
        await store.refresh()
        XCTAssertEqual(store.triedCount(in: .grainRoot), 1)

        store.removeRecord(id: pumpkin.id)

        XCTAssertEqual(
            FoodCellState.make(record: store.record(for: "pumpkin"), canRecord: true), .untried,
            "刪除後格子要回到「還沒吃」"
        )
        XCTAssertEqual(store.triedCount, 1)
        XCTAssertEqual(store.triedCount(in: .grainRoot), 0)
        XCTAssertEqual(store.record(for: "yogurt")?.id, yogurt.id, "其他格不受影響")
    }
}
