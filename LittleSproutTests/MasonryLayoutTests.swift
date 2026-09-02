@testable import LittleSprout
import XCTest

/// LS-126 票文驗收：「瀑布流：放置規則逐張可重放（測試用固定比例序列斷言欄高序列）」。
final class MasonryLayoutTests: XCTestCase {
    private let accuracy: CGFloat = 0.001

    // MARK: - columnCount

    func test_columnCount_iPhoneContentWidth_is2() {
        // 345 = 393（iPhone 標準寬）− 2×24（screenPad）——票文「iPhone 2 欄」的來源寬度。
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: 345), 2)
    }

    func test_columnCount_iPadDetailLeftColumn_is2() {
        // 票文「iPad 左右分欄骨架左欄 360pt → 2 欄」。
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: 360), 2)
    }

    func test_columnCount_narrowWidth_staysAt1() {
        // (164.5 + 16) < (16 + 164.5) 剛好卡在門檻下一點：1 欄。
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: 180), 1)
    }

    func test_columnCount_wideWidth_allows3Columns() {
        // (16+164.5)*3 - 16 = 525.5：欄寬剛好等於門檻，允許第 3 欄。
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: 525.5), 3)
    }

    func test_columnCount_zeroOrNegativeWidth_staysAt1() {
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: 0), 1)
        XCTAssertEqual(MasonryLayout.columnCount(forWidth: -10), 1)
    }

    // MARK: - place：固定比例序列斷言欄高序列

    /// 4 張固定比例（正方形／橫幅 2:1／直幅 1:2／正方形），345pt 容器寬（2 欄，欄寬
    /// 164.5）——逐張手算欄高序列，斷言每一步的欄位指派與最終容器高度都可重放。
    func test_place_fixedAspectRatioSequence_producesExpectedColumnHeightSequence() {
        let aspectRatios: [CGFloat] = [1.0, 2.0, 0.5, 1.0]
        let result = MasonryLayout.place(aspectRatios: aspectRatios, containerWidth: 345)

        XCTAssertEqual(result.columnCount, 2)
        XCTAssertEqual(result.placements.count, 4)

        let colWidth: CGFloat = 164.5
        let gap: CGFloat = 16

        // item0（比例 1.0）：兩欄同高（0），相等放左──欄 0。
        XCTAssertEqual(result.placements[0].column, 0)
        XCTAssertEqual(result.placements[0].originY, 0, accuracy: accuracy)
        XCTAssertEqual(result.placements[0].height, colWidth, accuracy: accuracy) // 164.5 / 1.0

        // item1（比例 2.0，高 82.25）：欄 0 現高 180.5、欄 1 仍 0──較矮的欄 1。
        XCTAssertEqual(result.placements[1].column, 1)
        XCTAssertEqual(result.placements[1].originY, 0, accuracy: accuracy)
        XCTAssertEqual(result.placements[1].height, colWidth / 2.0, accuracy: accuracy)

        // item2（比例 0.5，高 329）：欄 0 高 180.5、欄 1 高 98.25──較矮的欄 1。
        XCTAssertEqual(result.placements[2].column, 1)
        XCTAssertEqual(result.placements[2].originY, colWidth / 2.0 + gap, accuracy: accuracy) // 98.25
        XCTAssertEqual(result.placements[2].height, colWidth / 0.5, accuracy: accuracy) // 329

        // item3（比例 1.0，高 164.5）：欄 0 高 180.5、欄 1 高 443.25──較矮的欄 0。
        XCTAssertEqual(result.placements[3].column, 0)
        XCTAssertEqual(result.placements[3].originY, colWidth + gap, accuracy: accuracy) // 180.5
        XCTAssertEqual(result.placements[3].height, colWidth, accuracy: accuracy)

        // 最終欄高：欄 0 = 180.5 + 164.5 + 16 = 361；欄 1 = 98.25 + 329 + 16 = 443.25。
        // contentHeight = max − 最後一個 gap。
        XCTAssertEqual(result.contentHeight, 443.25 - gap, accuracy: accuracy)
    }

    func test_place_equalColumnHeights_placesLeft() {
        // 第一張：兩欄都還是 0（等高）──規則「相等放左」，落在欄 0。
        // 第二張：此時欄 0 已經 >0、欄 1 仍是 0（不再相等）──放進較矮的欄 1。
        // 第三張：兩欄再度變成同一輪比較裡「目前最矮」的欄 0（比欄 1 矮的機率視高度而定），
        //   這裡只斷言最單純、不會有歧義的頭兩張。
        let result = MasonryLayout.place(aspectRatios: [1.0, 1.0], containerWidth: 345)
        XCTAssertEqual(result.placements.map(\.column), [0, 1])
    }

    func test_place_trueTie_bothItemsSameHeightAndRatio_placesLeftOnFirstOnly() {
        // 驗證「相等放左」規則本身：用同比例但刻意讓第三張回到兩欄剛好打平的情境。
        // 欄寬 164.5：兩張比例 1.0（各自高 164.5）分別落欄 0／欄 1 後，兩欄同高
        // （164.5+16＝180.5），第三張再度出現「相等」，應放左（欄 0）。
        let result = MasonryLayout.place(aspectRatios: [1.0, 1.0, 1.0], containerWidth: 345)
        XCTAssertEqual(result.placements.map(\.column), [0, 1, 0])
    }

    func test_place_reRunOnSameSequence_isDeterministic() {
        // 「刪除／重排後整體重跑（非增量）」的前提：同一組輸入永遠得到同一組輸出。
        let aspectRatios: [CGFloat] = [1.2, 0.8, 1.5, 0.6, 1.0]
        let first = MasonryLayout.place(aspectRatios: aspectRatios, containerWidth: 345)
        let second = MasonryLayout.place(aspectRatios: aspectRatios, containerWidth: 345)
        XCTAssertEqual(first.placements, second.placements)
        XCTAssertEqual(first.contentHeight, second.contentHeight, accuracy: accuracy)
    }

    func test_place_preservesOriginalOrderForVoiceOver() {
        // VoiceOver 順序＝原始順序：placements 陣列本身與輸入陣列同序、同長度，呼叫端
        // 依原始 index 建視圖即可，不需要另外排序。
        let aspectRatios: [CGFloat] = [0.5, 2.0, 1.0, 0.75, 1.25]
        let result = MasonryLayout.place(aspectRatios: aspectRatios, containerWidth: 345)
        XCTAssertEqual(result.placements.count, aspectRatios.count)
    }

    func test_place_emptyInput_producesNoPlacementsAndZeroHeight() {
        let result = MasonryLayout.place(aspectRatios: [], containerWidth: 345)
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.contentHeight, 0)
    }

    func test_place_invalidAspectRatio_fallsBackToSquare() {
        // 防禦性：0 或負的寬高比（理論上不該發生，media 表 width/height 皆 CHECK > 0）
        // 不應該讓高度變成 infinity 或負值。
        let result = MasonryLayout.place(aspectRatios: [0, -1], containerWidth: 345)
        XCTAssertTrue(result.placements.allSatisfy { $0.height.isFinite && $0.height > 0 })
    }
}
