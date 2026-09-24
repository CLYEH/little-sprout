@testable import LittleSprout
import XCTest

/// LS-373：05 完成摘要對齊 LS-349 核可稿（D1–D5）的純函式——`Import05SummaryView` 的統計列、
/// Marking Section 文案與「補上寶貝」鈕 label 都取自 `Import05SummaryContent`，這裡鎖住
/// 數字契約與逐字文案（稿面 Notes `T5gSe`／`JKCKd`／`yGn3W`／`x73Dy6`）。
final class Import05SummaryContentTests: XCTestCase {
    // MARK: - 數字契約（D1）：成功＋沒有成功＋沒有加入＝總數，寶貝未指定是成功的子集

    /// 稿面 05 故事線：123 成功（其中 3 張寶貝沒有指定成功）＋2 沒有成功＋3 沒有加入＝128。
    /// 寶貝沒有指定成功的照片已經上傳成功——若把它做成獨立頂層列（R1 實作的 danger 列），總數
    /// 會多算 3 張，使用者看到的數字加不回開始匯入時的 128。
    func test_topLevelStatRows_sumToTotal_unassignedBabiesIsSubsetOfSucceeded() {
        let content = Import05SummaryContent(
            completedCount: 123, failedCount: 2, droppedCount: 3,
            markingFailedCount: 3, retryableMarkingFailedCount: 3
        )

        XCTAssertEqual(
            content.statRows.map(\.count).reduce(0, +), 128,
            "頂層列加總必須＝開始匯入時的總數（成功＋沒有成功＋沒有加入），寶貝未指定不得另計"
        )
        XCTAssertEqual(
            content.statRows,
            [.succeeded(count: 123, unassignedBabyCount: 3), .failed(count: 2), .dropped(count: 3)],
            "統計卡只有三類頂層列，寶貝未指定掛在成功列底下（D1）"
        )
    }

    /// 05b 故事線：128 張全部上傳成功、其中 3 張寶貝沒有指定成功——頂層只有成功一列，總數仍是
    /// 128，未指定張數不超過成功張數。
    func test_allUploadsSucceeded_withUnassignedBabies_totalStillEqualsSucceeded() {
        let content = Import05SummaryContent(
            completedCount: 128, failedCount: 0, droppedCount: 0,
            markingFailedCount: 3, retryableMarkingFailedCount: 2
        )

        XCTAssertEqual(content.statRows, [.succeeded(count: 128, unassignedBabyCount: 3)])
        XCTAssertEqual(content.statRows.map(\.count).reduce(0, +), 128)
    }

    func test_unassignedBabyLine_copyMatchesDesign() {
        XCTAssertEqual(Import05SummaryContent.unassignedBabyLine(count: 3), "其中 3 張的寶貝沒有指定成功")
    }

    // MARK: - Marking Section（D3／D4）

    func test_noMarkingFailure_hasNoMarkingSection() {
        let content = Import05SummaryContent(
            completedCount: 7, failedCount: 0, droppedCount: 0,
            markingFailedCount: 0, retryableMarkingFailedCount: 0
        )

        XCTAssertNil(content.markingSection, "全部成功時只剩成功統計＋主鈕（LS-251 原設計）")
    }

    /// 05（全部可補）：一組兩句＋按鈕。
    func test_allRetryable_oneGroupTwoSentences_withButton() {
        let content = Import05SummaryContent(
            completedCount: 123, failedCount: 2, droppedCount: 3,
            markingFailedCount: 3, retryableMarkingFailedCount: 3
        )

        XCTAssertEqual(
            content.markingSection,
            .init(
                header: "這 3 張的寶貝沒有指定成功",
                noteGroups: [["照片都匯入了。", "補上寶貝不會重新上傳照片。"]],
                fillableCount: 3
            )
        )
    }

    /// 05b（同批可補＋寶貝已移除）：「發生什麼／怎麼辦」兩組四句，按鈕只算可補的。
    func test_mixedRemovedAndRetryable_twoGroupsFourSentences_buttonCountsRetryableOnly() {
        let content = Import05SummaryContent(
            completedCount: 128, failedCount: 0, droppedCount: 0,
            markingFailedCount: 3, retryableMarkingFailedCount: 2
        )

        XCTAssertEqual(
            content.markingSection,
            .init(
                header: "這 3 張的寶貝沒有指定成功",
                noteGroups: [
                    ["照片都匯入了。", "1 張的寶貝已經移除，沒辦法指定。"],
                    ["另 2 張可以補上。", "補上寶貝不會重新上傳照片。"]
                ],
                fillableCount: 2
            )
        )
    }

    /// 全部都是 LS044：不給按鈕、不承諾之後能補。
    func test_allRemoved_noButton_noPromise() {
        let content = Import05SummaryContent(
            completedCount: 10, failedCount: 0, droppedCount: 0,
            markingFailedCount: 2, retryableMarkingFailedCount: 0
        )

        XCTAssertEqual(
            content.markingSection,
            .init(
                header: "這 2 張的寶貝沒有指定成功",
                noteGroups: [["照片都匯入了。", "選的寶貝已經移除，這 2 張沒辦法指定。"]],
                fillableCount: 0
            )
        )
    }

    // MARK: - 「補上寶貝」鈕（D3／D5）

    func test_fillBabiesButton_idle_isEnabled_withWordJoinerBeforeCount() {
        let presentation = Import05SummaryContent.fillBabiesButton(count: 3, isInFlight: false)

        XCTAssertEqual(presentation.title, "補上寶貝\u{2060}（3）", "（N）前放 U+2060，不得單獨斷行")
        XCTAssertFalse(presentation.isDisabled)
    }

    func test_fillBabiesButton_inFlight_isDisabled_withProgressCopy() {
        let presentation = Import05SummaryContent.fillBabiesButton(count: 3, isInFlight: true)

        XCTAssertEqual(presentation.title, "正在補上寶貝…")
        XCTAssertTrue(presentation.isDisabled, "請求進行中整顆停用，避免連點重送")
    }
}
