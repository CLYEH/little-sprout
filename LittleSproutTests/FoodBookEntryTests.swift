import Foundation
@testable import LittleSprout
import XCTest

/// LS-382：寶貝詳情「飲食圖鑑」入口的填格規則與文案（`FoodBookEntry`）。
///
/// 為什麼要鎖：入口三格是「最近吃過什麼、接下來試什麼」的摘要——排序錯了，家人看到的「最近」就不是最近；
/// 不補空位，0／1–2 筆時區塊變矮、下面的「看整本飲食圖鑑」跟著上移（Notes `h752D`「按鈕不位移」）；補位不照
/// `sort_order`，01b「可以從這三樣開始」就不是圖鑑的前三樣（Notes `wM6SX`）。
final class FoodBookEntryTests: XCTestCase {
    private static func item(_ id: String, _ sortOrder: Int, allergens: [String] = []) -> FoodCatalogItem {
        FoodCatalogItem(
            id: id, nameZh: id, category: .grainRoot, sortOrder: sortOrder, allergens: allergens, minAgeMonths: nil
        )
    }

    /// 目錄刻意不照 `sort_order` 排——函式自己要排，不能依賴呼叫端。
    private let catalog = [
        item("oatmeal", 3), item("rice_cereal", 1), item("white_rice", 4), item("rice_porridge", 2),
        item("banana", 100), item("tofu", 150), item("egg_yolk", 140)
    ]

    private func record(_ foodID: String, _ day: String, createdAt: String? = nil) throws -> ChildFoodRecord {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: day))
        let created = try XCTUnwrap(BirthdayFormat.date(fromWireString: createdAt ?? day))
        return ChildFoodRecord(
            id: UUID(), familyID: UUID(), childID: UUID(), foodID: foodID, authorID: nil, firstTriedOn: date,
            mediaID: nil, note: nil, reaction: nil, createdAt: created, updatedAt: created
        )
    }

    // MARK: - 補位排序

    /// 01：吃過的依 `first_tried_on` 新到舊（不是記錄建立順序、不是 `sort_order`），多出來的不顯示。
    func test_slots_triedNewestFirst_capsAtCount() throws {
        let records = try [
            record("egg_yolk", "2026-07-05"), record("banana", "2026-08-02"),
            record("rice_cereal", "2025-10-22"), record("tofu", "2026-07-19")
        ]
        let slots = FoodBookEntry.slots(catalog: catalog, records: records, count: 3)
        XCTAssertEqual(slots.map(\.id), ["banana", "tofu", "egg_yolk"])
        XCTAssertTrue(slots.allSatisfy { $0.record != nil })
    }

    /// 01c：1 筆吃過排第一，其餘依 `sort_order` 補「還沒吃」（跳過已吃的米精）；01b：0 筆＝`sort_order` 前三。
    func test_slots_fillUntriedBySortOrder_skippingTried() throws {
        let one = FoodBookEntry.slots(catalog: catalog, records: [try record("rice_cereal", "2025-10-22")], count: 3)
        XCTAssertEqual(one.map(\.id), ["rice_cereal", "rice_porridge", "oatmeal"])
        XCTAssertEqual(one.map { $0.record != nil }, [true, false, false])

        let empty = FoodBookEntry.slots(catalog: catalog, records: [], count: 3)
        XCTAssertEqual(empty.map(\.id), ["rice_cereal", "rice_porridge", "oatmeal"])
        XCTAssertTrue(empty.allSatisfy { $0.record == nil })

        let iPad = FoodBookEntry.slots(catalog: catalog, records: [try record("oatmeal", "2026-01-05")], count: 5)
        XCTAssertEqual(iPad.map(\.id), ["oatmeal", "rice_cereal", "rice_porridge", "white_rice", "banana"])
    }

    /// 格子數固定——三態（0／1–2／≥3 筆）都是 `count` 格，這是「區塊等高、按鈕不位移」的前提。
    func test_slots_countIsConstantAcrossStates() throws {
        let states: [[ChildFoodRecord]] = try [
            [],
            [record("banana", "2026-08-02")],
            [record("banana", "2026-08-02"), record("tofu", "2026-07-19")],
            [record("banana", "2026-08-02"), record("tofu", "2026-07-19"), record("egg_yolk", "2026-07-05"),
             record("rice_cereal", "2025-10-22")]
        ]
        for records in states {
            XCTAssertEqual(FoodBookEntry.slots(catalog: catalog, records: records, count: 3).count, 3)
            XCTAssertEqual(FoodBookEntry.slots(catalog: catalog, records: records, count: 5).count, 5)
        }
    }

    /// 同一天吃到好幾樣：後記的在前，再依 `sort_order`——全序，重繪不換位置。
    func test_slots_sameDayTieBreaksByCreatedAtThenSortOrder() throws {
        let records = try [
            record("tofu", "2026-07-19", createdAt: "2026-07-19"),
            record("banana", "2026-07-19", createdAt: "2026-07-20"),
            record("egg_yolk", "2026-07-19", createdAt: "2026-07-19")
        ]
        let slots = FoodBookEntry.slots(catalog: catalog, records: records, count: 3)
        XCTAssertEqual(slots.map(\.id), ["banana", "egg_yolk", "tofu"])
    }

    /// 記錄指向已下架（目錄裡沒有）的食物：不佔格、也不擋補位（同 `FoodBookStore.triedCount` 的分子規則）。
    func test_slots_ignoresRecordsOutsideCatalog() throws {
        let slots = FoodBookEntry.slots(
            catalog: catalog, records: [try record("retired_food", "2026-08-10"), try record("banana", "2026-08-02")],
            count: 3
        )
        XCTAssertEqual(slots.map(\.id), ["banana", "rice_cereal", "rice_porridge"])
    }

    // MARK: - 文案（逐字對稿）

    func test_countLine_threeStatesMatchDesign() throws {
        let recent = try [
            record("banana", "2026-08-02"), record("tofu", "2026-07-19"), record("egg_yolk", "2026-07-05")
        ]
        let full = FoodBookEntry.slots(catalog: catalog, records: recent, count: 3)
        XCTAssertEqual(
            FoodBookEntry.countLine(childName: "小安", triedCount: 38, totalCount: 274, slots: full),
            "小安吃過 38／274\u{00A0}種，最近三樣：", "01 `MQ01U`"
        )
        let empty = FoodBookEntry.slots(catalog: catalog, records: [], count: 3)
        XCTAssertEqual(
            FoodBookEntry.countLine(childName: "小安", triedCount: 0, totalCount: 274, slots: empty),
            "小安吃過 0／274\u{00A0}種，可以從這三樣開始：", "01b `A79NZ`"
        )
        let one = FoodBookEntry.slots(catalog: catalog, records: [try record("rice_cereal", "2025-10-22")], count: 3)
        XCTAssertEqual(
            FoodBookEntry.countLine(childName: "小安", triedCount: 1, totalCount: 274, slots: one),
            "小安吃過 1／274\u{00A0}種，最近和接著試的：", "01c `fKTwC`"
        )
    }

    func test_countLine_iPadFiveSlots() throws {
        let records = try ["banana", "tofu", "egg_yolk", "rice_cereal", "oatmeal"].enumerated().map {
            try record($0.element, "2026-0\($0.offset + 1)-01")
        }
        let slots = FoodBookEntry.slots(catalog: catalog, records: records, count: 5)
        XCTAssertEqual(
            FoodBookEntry.countLine(childName: "小安", triedCount: 38, totalCount: 274, slots: slots),
            "小安吃過 38／274\u{00A0}種，最近五樣：", "01-iPad `w25F3`"
        )
    }

    func test_bookButtonTitle() {
        XCTAssertEqual(FoodBookEntry.bookButtonTitle(triedCount: 38, isAccessibilityLayout: false), "看整本飲食圖鑑")
        XCTAssertEqual(FoodBookEntry.bookButtonTitle(triedCount: 38, isAccessibilityLayout: true), "看整本圖鑑")
        XCTAssertEqual(FoodBookEntry.bookButtonTitle(triedCount: 0, isAccessibilityLayout: false), "打開飲食圖鑑")
    }
}
