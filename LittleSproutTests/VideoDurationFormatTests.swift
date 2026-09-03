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

    /// LS-135：`M:SS` 沒有小時進位，分鐘數本來就不封頂在 59——`media.duration_seconds` 的
    /// 上游沒有對影片長度設任何上限（不像 `DiaryDurationFormat.maxPublishDuration` 的發佈
    /// 60 秒上限，這裡格式化的是已經量測到的實際時長，不是發佈流程截斷後的值），確保
    /// ≥60 分鐘也不會意外冒出第三段（"1:01:05"）或截斷成兩位數。
    func test_badgeText_atLeast60Minutes_doesNotCarryIntoHours() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 3665), "影片 61:05")
    }
}
