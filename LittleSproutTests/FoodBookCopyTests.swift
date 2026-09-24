import Foundation
@testable import LittleSprout
import XCTest

/// LS-379：飲食圖鑑 02 家族的文案、對映表與格子狀態映射——逐字對稿（`design/littlesprout.pen`
/// `azRUz`／`raups`／`nO7yz`／`UbcMH`／`r3uREQ`；Notes `v5KLRQ`／`vMFj3`／`J8qvq5`）。
///
/// 為什麼要鎖這些：計數句與「吃過 N／M」是這個畫面唯一的「收集感」回饋，分子分母錯一格使用者就會
/// 懷疑記錄沒存進去；過敏原小標是純資訊的健康提醒，對映錯字（例如 wheat 印成「含小麥」而不是
/// 「含麩質」）等於給錯資訊；viewer 能點空位會導向一個注定 42501 的寫入畫面。
final class FoodBookCopyTests: XCTestCase {
    // MARK: - 計數句（範圍 1）

    func test_progressSentence_matchesDesignWithNBSPBeforeUnit() {
        let sentence = FoodBookCopy.progressSentence(childName: "小安", triedCount: 38, totalCount: 274)
        // 稿面 `azRUz` 逐字；「種」前是 U+00A0（Notes MN-13），AX3 下「種」不會被單獨折到下一行。
        XCTAssertEqual(sentence, "小安吃過 38\u{00A0}種，全部 274\u{00A0}種。")
    }

    func test_progressSentence_largeNumbersHaveNoGroupingSeparator() {
        // `Text` 對 Int 插值會套千分位（LS-313 的「2,026年」事故）；這裡的字串絕不能出現逗號分隔。
        let sentence = FoodBookCopy.progressSentence(childName: "小安", triedCount: 1234, totalCount: 5678)
        XCTAssertEqual(sentence, "小安吃過 1234\u{00A0}種，全部 5678\u{00A0}種。")
    }

    func test_categoryCount_usesFullWidthSlash() {
        XCTAssertEqual(FoodBookCopy.categoryCount(triedCount: 10, totalCount: 16), "吃過 10／16")
        XCTAssertEqual(FoodBookCopy.categoryCount(triedCount: 0, totalCount: 10), "吃過 0／10")
    }

    func test_tapHint_memberAndViewerVariants() {
        XCTAssertEqual(FoodBookCopy.tapHint(canRecord: true), "點灰色的格子，就能記下第一次吃到的日子。")
        XCTAssertEqual(FoodBookCopy.tapHint(canRecord: false), "這本圖鑑由家人記錄，你可以隨時翻看。")
    }

    func test_disclaimer_matchesDesignVerbatim() {
        XCTAssertEqual(
            FoodBookCopy.disclaimer,
            "標「含〇〇」的是常見過敏原，標「一歲後」的建議滿一歲再吃。這些只是提醒，不是醫療建議；有疑問請問醫師。"
        )
    }

    // MARK: - 過敏原／一歲後小標（範圍 3）

    /// DB `food_catalog_allergens_valid` 的 10 個值（LS-347 起）必須全部有中文名——漏一個，那一類食物的
    /// 小標就會退回「含過敏原」這種沒資訊量的字。
    func test_allergenNames_coverAllTenDatabaseValues() {
        let databaseValues = [
            "egg", "milk", "peanut", "tree_nut", "shellfish", "fish", "wheat", "soy", "sesame", "mango"
        ]
        XCTAssertEqual(Set(FoodBookCopy.allergenNames.keys), Set(databaseValues))
    }

    func test_allergenTag_mapping() {
        XCTAssertNil(FoodBookCopy.allergenTag([]), "沒有過敏原＝整列不顯示")
        XCTAssertEqual(FoodBookCopy.allergenTag(["egg"]), "含蛋")
        XCTAssertEqual(FoodBookCopy.allergenTag(["milk"]), "含牛奶")
        XCTAssertEqual(FoodBookCopy.allergenTag(["peanut"]), "含花生")
        XCTAssertEqual(FoodBookCopy.allergenTag(["tree_nut"]), "含堅果")
        XCTAssertEqual(FoodBookCopy.allergenTag(["shellfish"]), "含甲殼類")
        XCTAssertEqual(FoodBookCopy.allergenTag(["fish"]), "含魚")
        // wheat 的語意是「含麩質穀物代理」（API.md §3），不是字面小麥。
        XCTAssertEqual(FoodBookCopy.allergenTag(["wheat"]), "含麩質")
        XCTAssertEqual(FoodBookCopy.allergenTag(["soy"]), "含大豆")
        XCTAssertEqual(FoodBookCopy.allergenTag(["sesame"]), "含芝麻")
        XCTAssertEqual(FoodBookCopy.allergenTag(["mango"]), "含芒果")
    }

    func test_allergenTag_multipleUsesFirstPlusDeng() {
        // 稿面 02b 布丁（`milk_pudding`，allergens `milk;egg`）＝「含牛奶等」。
        XCTAssertEqual(FoodBookCopy.allergenTag(["milk", "egg"]), "含牛奶等")
    }

    func test_allergenTag_unknownCodeNeverLeaksEnglish() {
        XCTAssertEqual(FoodBookCopy.allergenTag(["sulfite"]), "含過敏原")
    }

    /// D1a（使用者 09-24）：滿一歲後「一歲後」仍顯示——`ageTag` 結構上不收孩子生日，這裡鎖住
    /// 「只看 min_age_months」。
    func test_ageTag_onlyDependsOnMinAgeMonths() {
        XCTAssertEqual(FoodBookCopy.ageTag(minAgeMonths: 12), "一歲後")
        XCTAssertNil(FoodBookCopy.ageTag(minAgeMonths: nil))
        XCTAssertEqual(FoodBookCopy.ageTag(minAgeMonths: 24), "滿24個月後", "非 12 的月數照實寫出，不默默吞掉")
    }

    // MARK: - 日期 yyyy/M/d

    func test_cellDate_noZeroPadding() throws {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2025-11-03"))
        XCTAssertEqual(FoodBookCopy.cellDate(date), "2025/11/3")
        let january = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-01-05"))
        XCTAssertEqual(FoodBookCopy.cellDate(january), "2026/1/5")
    }

    /// `first_tried_on` 解成 UTC 午夜；顯示必須用 UTC 抽年月日——用裝置時區（UTC-） 會退成前一天。
    func test_cellDate_usesUTCDayRegardlessOfDeviceTimeZone() throws {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-06-08"))
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = original }
        XCTAssertEqual(FoodBookCopy.cellDate(date), "2026/6/8")
    }

    // MARK: - 格子狀態映射（範圍 2／4）

    func test_cellState_triedUntriedViewerMapping() throws {
        let record = try Self.record(foodID: "pumpkin", day: "2025-11-18")
        XCTAssertEqual(FoodCellState.make(record: record, canRecord: true), .tried(firstTriedOn: record.firstTriedOn))
        XCTAssertEqual(
            FoodCellState.make(record: record, canRecord: false), .tried(firstTriedOn: record.firstTriedOn),
            "viewer 看得到吃過的紙片（同一份資料，不分角色）"
        )
        XCTAssertEqual(FoodCellState.make(record: nil, canRecord: true), .untried)
        XCTAssertEqual(FoodCellState.make(record: nil, canRecord: false), .untriedReadOnly)
    }

    /// viewer 的空位不是按鈕（02c `jo5h8`）；吃過的格子任何角色都能點進去看詳情（Notes `J8qvq5`）；
    /// owner／member 的空位可點（開第一次記錄）。
    func test_cellState_interactivity() {
        XCTAssertTrue(FoodCellState.tried(firstTriedOn: Date()).isInteractive)
        XCTAssertTrue(FoodCellState.untried.isInteractive)
        XCTAssertFalse(FoodCellState.untriedReadOnly.isInteractive)
    }

    func test_cellAccessibilityLabel_readsUntriedAndTags() throws {
        let milk = FoodCatalogItem(
            id: "fresh_milk", nameZh: "鮮奶", category: .dairy, sortOrder: 226, allergens: ["milk"], minAgeMonths: 12
        )
        XCTAssertEqual(
            FoodBookCopy.cellAccessibilityLabel(item: milk, state: .untried), "鮮奶，還沒吃過，含牛奶，一歲後"
        )
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-05-02"))
        XCTAssertEqual(
            FoodBookCopy.cellAccessibilityLabel(item: milk, state: .tried(firstTriedOn: date)),
            "鮮奶，2026/5/2 第一次吃到，含牛奶，一歲後"
        )
    }

    static func record(foodID: String, day: String) throws -> ChildFoodRecord {
        let date = try XCTUnwrap(BirthdayFormat.date(fromWireString: day))
        return ChildFoodRecord(
            id: UUID(), familyID: UUID(), childID: UUID(), foodID: foodID, authorID: nil, firstTriedOn: date,
            mediaID: nil, note: nil, reaction: nil, createdAt: date, updatedAt: date
        )
    }
}
