import Foundation
@testable import LittleSprout
import XCTest

/// `GrowthMeasurementValidation`（LS-313，02 新增／編輯量測 sheet）：全空擋下儲存＋至少一項
/// 通過＋範圍軟提醒不擋儲存三條票文驗收條件的純函式層保證。
final class GrowthMeasurementValidationTests: XCTestCase {
    // MARK: - hasAtLeastOneValue

    /// mutation：若 `hasAtLeastOneValue` 改成永遠回傳 `true`，這支測試會抓到——三項全空必須
    /// 擋下儲存（票文驗收「全空」）。
    func test_hasAtLeastOneValue_allNil_false() {
        XCTAssertFalse(GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: nil, weightKg: nil, headCm: nil))
    }

    /// mutation：若改成 `heightCm != nil && weightKg != nil && headCm != nil`（要求全部都填，
    /// 誤把「至少一項」寫成「全部都要」），這支測試會抓到——只填一項就該通過（票文驗收
    /// 「至少一項」）。
    func test_hasAtLeastOneValue_onlyHeight_true() {
        XCTAssertTrue(GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: 78.5, weightKg: nil, headCm: nil))
    }

    func test_hasAtLeastOneValue_onlyWeight_true() {
        XCTAssertTrue(GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: nil, weightKg: 9.6, headCm: nil))
    }

    func test_hasAtLeastOneValue_onlyHead_true() {
        XCTAssertTrue(GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: nil, weightKg: nil, headCm: 45.0))
    }

    func test_hasAtLeastOneValue_allFilled_true() {
        XCTAssertTrue(GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: 78.5, weightKg: 9.6, headCm: 45.0))
    }

    // MARK: - rangeWarning（軟提醒，不擋儲存——這支只驗訊息本身，「不擋儲存」是 View 層
    // `submit()` 從不讀這支函式的回傳值來決定要不要呼叫 API 的行為面保證，見
    // `GrowthMeasurementFormView.submit()`）

    /// mutation：若門檻判斷從 `>` 改成 `>=`，這支測試會抓到——Notes 例句用的 180.0 剛好要能
    /// 觸發，門檻本身（130.0）不該被觸發到。
    func test_rangeWarning_withinNormalRange_nil() {
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: 78.5, weightKg: 9.6, headCm: 45.0))
    }

    /// Notes `hQpxd` 例句：「身高 180.0 cm 比同齡孩子高很多。如果沒有打錯，直接儲存就可以。」
    func test_rangeWarning_heightOverThreshold_matchesNotesExample() {
        XCTAssertEqual(
            GrowthMeasurementValidation.rangeWarning(heightCm: 180.0, weightKg: nil, headCm: nil),
            "身高 180.0 cm 比同齡孩子高很多。如果沒有打錯，直接儲存就可以。"
        )
    }

    func test_rangeWarning_weightOverThreshold_mentionsWeight() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 45.0, headCm: nil)
        XCTAssertEqual(message, "體重 45.0 kg 比同齡孩子重很多。如果沒有打錯，直接儲存就可以。")
    }

    func test_rangeWarning_headOverThreshold_mentionsHead() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 65.0)
        XCTAssertEqual(message, "頭圍 65.0 cm 比同齡孩子大很多。如果沒有打錯，直接儲存就可以。")
    }

    /// mutation：若三個 `if` 判斷順序或提前 `return` 被拿掉（例如改成同時回傳多條訊息），這支
    /// 測試會抓到——Range Warning Slot 只有一個插槽，只回傳第一個超出範圍的項目（依身高／
    /// 體重／頭圍的欄位視覺順序）。
    func test_rangeWarning_multipleFieldsOverThreshold_onlyReturnsFirst() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: 180.0, weightKg: 45.0, headCm: 65.0)
        XCTAssertEqual(
            message, "身高 180.0 cm 比同齡孩子高很多。如果沒有打錯，直接儲存就可以。",
            "三項同時超出範圍時，只回傳身高（視覺順序最前）那一條，不是全部列出"
        )
    }

    func test_rangeWarning_allNil_nil() {
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: nil))
    }
}
