@testable import LittleSprout
import XCTest

final class VideoDurationFormatTests: XCTestCase {
    func test_badgeText_nilDuration_showsPlainLabel() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: nil), "影片")
    }

    func test_badgeText_truncatesAndPadsSeconds() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 5), "影片 0:05")
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 65), "影片 1:05")
        // merge-review R1 i2：無條件捨去，不四捨五入（對齊 LS-125 DiaryDurationFormat 的
        // 慣例）——599.6 秒捨去到 599 秒＝9 分 59 秒，不是進位到 600 秒＝10:00。
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 599.6), "影片 9:59")
    }

    func test_badgeText_negativeDuration_clampsToZero() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: -1), "影片 0:00")
    }
}
