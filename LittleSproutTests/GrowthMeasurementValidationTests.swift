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
    // `GrowthMeasurementPrefillRegressionTests.test_submit_neverGatesOnRangeWarning`）

    /// R1 merge-review m2（修正舊註解——原本聲稱能抓 `>`→`>=` 的 mutation，但輸入離門檻很
    /// 遠，抓不到；`ClosedRange.contains` 也不是 `>`/`>=` 的形狀）：一般常見量測值（遠在
    /// 區間內）不該觸發，邊界精確值見下面 `test_rangeWarning_exactlyAtBoundaries_nil`。
    func test_rangeWarning_withinNormalRange_nil() {
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: 78.5, weightKg: 9.6, headCm: 45.0))
    }

    /// R1 merge-review m2：邊界值本身（區間端點）不該觸發——`ClosedRange.contains` 是雙端
    /// 包含，剛好等於上限／下限都算「在範圍內」。mutation：若把 `heightRange` 的
    /// `30.0...200.0` 誤改成不含端點的判斷，這支測試會抓到。
    func test_rangeWarning_exactlyAtBoundaries_nil() {
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: 30.0, weightKg: nil, headCm: nil))
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: 200.0, weightKg: nil, headCm: nil))
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 1.0, headCm: nil))
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 150.0, headCm: nil))
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 25.0))
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 70.0))
    }

    /// 緊貼邊界外一格——剛好超出區間就該觸發，門檻不能鬆一格。
    func test_rangeWarning_justOutsideBoundaries_triggers() {
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: 29.9, weightKg: nil, headCm: nil))
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: 200.1, weightKg: nil, headCm: nil))
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 0.9, headCm: nil))
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 150.1, headCm: nil))
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 24.9))
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 70.1))
    }

    /// R1 merge-review M4：門檻改成年齡無關的合理區間（上下限皆有）；orchestrator 裁決
    /// `d55ff9ac` 第 5 條例句：「身高 220.0 cm 看起來不太尋常。如果沒有打錯，直接儲存就可
    /// 以。」（原 Notes `hQpxd` 例句的 180.0 落在新上限 200.0 之內，改用超出新上限的 220.0）。
    func test_rangeWarning_heightOverUpperBound_matchesDecisionExample() {
        XCTAssertEqual(
            GrowthMeasurementValidation.rangeWarning(heightCm: 220.0, weightKg: nil, headCm: nil),
            "身高 220.0 cm 看起來不太尋常。如果沒有打錯，直接儲存就可以。"
        )
    }

    func test_rangeWarning_weightOverUpperBound_mentionsWeight() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: 160.0, headCm: nil)
        XCTAssertEqual(message, "體重 160.0 kg 看起來不太尋常。如果沒有打錯，直接儲存就可以。")
    }

    func test_rangeWarning_headUnderLowerBound_mentionsHead() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: 4.5)
        XCTAssertEqual(message, "頭圍 4.5 cm 看起來不太尋常。如果沒有打錯，直接儲存就可以。")
    }

    /// mutation：若三個 `if` 判斷順序或提前 `return` 被拿掉（例如改成同時回傳多條訊息），這支
    /// 測試會抓到——Range Warning Slot 只有一個插槽，只回傳第一個超出範圍的項目（依身高／
    /// 體重／頭圍的欄位視覺順序）。
    func test_rangeWarning_multipleFieldsOverThreshold_onlyReturnsFirst() {
        let message = GrowthMeasurementValidation.rangeWarning(heightCm: 220.0, weightKg: 160.0, headCm: 75.0)
        XCTAssertEqual(
            message, "身高 220.0 cm 看起來不太尋常。如果沒有打錯，直接儲存就可以。",
            "三項同時超出範圍時，只回傳身高（視覺順序最前）那一條，不是全部列出"
        )
    }

    func test_rangeWarning_allNil_nil() {
        XCTAssertNil(GrowthMeasurementValidation.rangeWarning(heightCm: nil, weightKg: nil, headCm: nil))
    }

    // MARK: - parsedMeasurement（R1 merge-review m1）

    /// mutation：若拿掉逗號正規化這一步，這支測試會抓到——逗號小數點地區的裝置會打出這種
    /// 文字，不能被靜默解析成 nil。
    func test_parsedMeasurement_commaDecimalSeparator_parsesAsDot() {
        XCTAssertEqual(GrowthMeasurementValidation.parsedMeasurement(from: "9,6"), 9.6)
    }

    /// mutation：若拿掉四捨五入到一位小數這一步，這支測試會抓到——票文「小數一位」，兩位小數
    /// 的輸入要被收斂成一位，不能整段原封不動存進去。
    func test_parsedMeasurement_twoDecimalPlaces_roundsToOneDecimal() {
        XCTAssertEqual(GrowthMeasurementValidation.parsedMeasurement(from: "9.66"), 9.7)
    }

    /// mutation：若拿掉 `value > 0` 這個條件，這支測試會抓到——DB `growth_records_height_
    /// positive` 等 CHECK 約束擋 0，前端要先擋，不能等 RPC 回 `23514`。
    func test_parsedMeasurement_zero_returnsNil() {
        XCTAssertNil(GrowthMeasurementValidation.parsedMeasurement(from: "0"))
    }

    /// mutation：若拿掉上限判斷，這支測試會抓到——超出 `numeric` 欄位容量的值前端要先擋，不能
    /// 等 RPC 回 `22003`。
    func test_parsedMeasurement_overUpperLimit_returnsNil() {
        XCTAssertNil(GrowthMeasurementValidation.parsedMeasurement(from: "1000"))
    }

    func test_parsedMeasurement_empty_returnsNil() {
        XCTAssertNil(GrowthMeasurementValidation.parsedMeasurement(from: ""))
    }

    func test_parsedMeasurement_garbage_returnsNil() {
        XCTAssertNil(GrowthMeasurementValidation.parsedMeasurement(from: "abc"))
    }

    func test_parsedMeasurement_validOneDecimal_unchanged() {
        XCTAssertEqual(GrowthMeasurementValidation.parsedMeasurement(from: "78.5"), 78.5)
    }

    // MARK: - submitDecision（merge-review R2 finding：非空但無效的欄位不能被靜默當成「沒填」）

    /// 編輯既有筆時把身高打成 0（或 1000、`9..6`），體重照舊——現況會存成 `height_cm = NULL`
    /// （`upsert_growth_record` 的 update 分支 `height_cm = p_height_cm`），既有身高被靜默清掉。
    func test_submitDecision_nonEmptyInvalidField_isInvalidNotSilentlyDropped() {
        for bad in ["0", "0.0", "1000", "9..6", "abc"] {
            XCTAssertEqual(
                GrowthMeasurementValidation.submitDecision(heightText: bad, weightText: "12.5", headText: ""),
                .invalid, "身高「\(bad)」非空但無效，不能被當成沒填、只存體重"
            )
        }
    }

    /// 全空仍是 `.empty`（「請至少填寫…」），不是 `.invalid`。
    func test_submitDecision_allBlank_isEmpty() {
        XCTAssertEqual(
            GrowthMeasurementValidation.submitDecision(heightText: " ", weightText: "", headText: ""), .empty
        )
    }

    /// 品牌第 8 條：超出合理範圍（軟提醒）照樣 `.save`——這是「範圍提醒不擋儲存」的行為面測試。
    func test_submitDecision_outOfSoftRange_stillSaves() {
        XCTAssertNotNil(GrowthMeasurementValidation.rangeWarning(heightCm: 250.0, weightKg: nil, headCm: nil))
        XCTAssertEqual(
            GrowthMeasurementValidation.submitDecision(heightText: "250", weightText: "", headText: ""),
            .save(heightCm: 250.0, weightKg: nil, headCm: nil)
        )
    }

    /// 四捨五入到一位後變 0（`0.04`→`0.0`）不能送出——`value > 0` 要檢查四捨五入後的值，否則撞 DB `23514`。
    func test_parsedMeasurement_roundsToZero_returnsNil() {
        XCTAssertNil(GrowthMeasurementValidation.parsedMeasurement(from: "0.04"))
    }

    // MARK: - submission（LS-335，LS-313 R3-m2：`submit()` 的整段決策）

    /// 編輯既有紀錄、身高改成 `0`、體重照舊——不能送出（`upsert_growth_record` 的 update 分支會把
    /// 既有身高清成 NULL），而是回 `.invalid`（Status Slot 顯示無效值訊息、sheet 不關）。
    /// mutation：把 `submission` 接回 R2 行為（只用 `hasAtLeastOneValue` 擋全空、無效值被
    /// `parsedMeasurement` 當成 nil 照樣送出），這支測試轉紅。
    func test_submission_editingRecordHeightZero_isInvalidNotSent() {
        let submission = GrowthMeasurementValidation.submission(
            .init(height: "0", weight: "9.6", head: "45.0", note: ""), editingID: UUID(), measuredOn: Date()
        )

        XCTAssertEqual(submission, .invalid, "身高改成 0 不能被當成沒填送出——既有身高會被清成 NULL")
    }

    func test_submission_allBlank_isEmpty() {
        let submission = GrowthMeasurementValidation.submission(
            .init(height: "", weight: " ", head: "", note: "有備註"), editingID: nil, measuredOn: Date()
        )

        XCTAssertEqual(submission, .empty, "只有備註、三項量測全空不能送出")
    }

    /// 送出的 input 帶編輯中紀錄的 `id`（走 update 分支）、解析後的數值與去頭尾空白的備註；空白
    /// 備註送 `nil`。
    func test_submission_valid_sendsParsedInput() throws {
        let editingID = UUID()
        let measuredOn = try XCTUnwrap(BirthdayFormat.date(fromWireString: "2026-08-20"))

        let submission = GrowthMeasurementValidation.submission(
            .init(height: "78,5", weight: "", head: "45", note: "  打完疫苗  "), editingID: editingID,
            measuredOn: measuredOn
        )
        let blankNote = GrowthMeasurementValidation.submission(
            .init(height: "78.5", weight: "", head: "", note: "  \n"), editingID: nil, measuredOn: measuredOn
        )

        XCTAssertEqual(submission, .send(GrowthMeasurementInput(
            id: editingID, measuredOn: measuredOn, heightCm: 78.5, weightKg: nil, headCm: 45.0, note: "打完疫苗"
        )))
        XCTAssertEqual(blankNote, .send(GrowthMeasurementInput(
            id: nil, measuredOn: measuredOn, heightCm: 78.5, weightKg: nil, headCm: nil, note: nil
        )), "空白備註送 nil，不送空字串")
    }
}
