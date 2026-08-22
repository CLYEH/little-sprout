import XCTest
@testable import LittleSprout

/// LS-7 紅燈驗證用：刻意失敗的測試，證明 CI 真的在跑 test（而非本機 hook
/// 被繞過後 CI 靜默放行）。驗證完會被移除。
final class DeliberateFailureTests: XCTestCase {
    func testDeliberatelyFailsForCIRedGreenVerification() {
        XCTAssertEqual(
            AppSection.allCases.count,
            99,
            "LS-7 紅燈驗證：此測試應該失敗，證明 CI 真的執行了測試"
        )
    }
}
