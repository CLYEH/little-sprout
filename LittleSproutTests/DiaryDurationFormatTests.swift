@testable import LittleSprout
import XCTest

final class DiaryDurationFormatTests: XCTestCase {
    func test_string_belowOneMinute() {
        XCTAssertEqual(DiaryDurationFormat.string(from: 32), "0:32")
    }

    func test_string_padsSecondsUnderTen() {
        XCTAssertEqual(DiaryDurationFormat.string(from: 65), "1:05")
    }

    func test_string_overOneMinute() {
        XCTAssertEqual(DiaryDurationFormat.string(from: 84), "1:24")
    }

    func test_string_truncatesFractionalSeconds() {
        XCTAssertEqual(DiaryDurationFormat.string(from: 32.9), "0:32", "M:SS 是粗略時長，無條件捨去而非四捨五入")
    }

    func test_string_negativeDuration_clampsToZero() {
        XCTAssertEqual(DiaryDurationFormat.string(from: -5), "0:00")
    }

    func test_exceedsMaxPublishDuration_atExactly60_isFalse() {
        XCTAssertFalse(DiaryDurationFormat.exceedsMaxPublishDuration(60))
    }

    func test_exceedsMaxPublishDuration_over60_isTrue() {
        XCTAssertTrue(DiaryDurationFormat.exceedsMaxPublishDuration(60.1))
    }

    func test_exceedsMaxPublishDuration_under60_isFalse() {
        XCTAssertFalse(DiaryDurationFormat.exceedsMaxPublishDuration(59))
    }
}
