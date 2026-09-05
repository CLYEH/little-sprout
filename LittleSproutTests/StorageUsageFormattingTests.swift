import XCTest
@testable import LittleSprout

/// LS-188：09／09b 儲存空間頁的格式化純函式——`gbString`（用量／上限文案）與
/// `filledChipCount`（Print Roll 12 格中填滿幾格）。兩者都不吃任何 async 依賴，直接測輸入
/// 輸出，不需要建構整個 `StorageUsageView`。
final class StorageUsageFormattingTests: XCTestCase {
    // MARK: - gbString

    func testGbString_wholeNumber_omitsDecimalPoint() {
        // 稿面「／ 5 GB」不是「／ 5.0 GB」。
        XCTAssertEqual(StorageUsageView.gbString(5_368_709_120), "5 GB")
    }

    func testGbString_fractional_oneDecimalPlace() {
        // 稿面「2.1 GB 已使用」。
        XCTAssertEqual(StorageUsageView.gbString(2_254_857_830), "2.1 GB")
    }

    func testGbString_zero() {
        XCTAssertEqual(StorageUsageView.gbString(0), "0 GB")
    }

    // MARK: - filledChipCount

    func testFilledChipCount_42Percent_matchesDesignSample() {
        // 稿面 09：2.1／5 GB＝42%→12 格中的 5 格。
        XCTAssertEqual(StorageUsageView.filledChipCount(usedFraction: 0.42), 5)
    }

    func testFilledChipCount_full_matchesDesignSample() {
        // 稿面 09b：100%→12 格中的 12 格。
        XCTAssertEqual(StorageUsageView.filledChipCount(usedFraction: 1.0), 12)
    }

    func testFilledChipCount_zero() {
        XCTAssertEqual(StorageUsageView.filledChipCount(usedFraction: 0), 0)
    }

    func testFilledChipCount_clampsWithinZeroToTwelve() {
        XCTAssertEqual(StorageUsageView.filledChipCount(usedFraction: -0.5), 0)
        XCTAssertEqual(StorageUsageView.filledChipCount(usedFraction: 1.5), 12)
    }
}
