@testable import LittleSprout
import XCTest

final class VideoDurationFormatTests: XCTestCase {
    func test_badgeText_nilDuration_showsPlainLabel() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: nil), "影片")
    }

    func test_badgeText_roundsAndPadsSeconds() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 5), "影片 0:05")
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 65), "影片 1:05")
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: 599.6), "影片 10:00")
    }

    func test_badgeText_negativeDuration_clampsToZero() {
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: -1), "影片 0:00")
    }
}
