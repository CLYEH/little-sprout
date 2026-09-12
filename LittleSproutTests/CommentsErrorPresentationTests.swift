@testable import LittleSprout
import XCTest

/// LS-218：`CommentsErrorPresentation.make(from:)`——LS026 與網路錯誤分流（票文範圍 4）。
final class CommentsErrorPresentationTests: XCTestCase {
    func test_targetFamilyMismatch_mapsToTargetGone_noRetry() {
        let error = AppError.rejected(message: "target 屬於別的家庭", code: LSErrorCode.targetFamilyMismatch.rawValue)

        let presentation = CommentsErrorPresentation.make(from: error)

        XCTAssertEqual(presentation, .targetGone)
        XCTAssertFalse(presentation.showsRetry, "LS026 是目標真的不在了，不該給重試")
        XCTAssertTrue(presentation.isTargetGone)
    }

    func test_networkError_mapsToNetworkPresentation_withRetry() {
        let error = AppError.network(message: "offline")

        let presentation = CommentsErrorPresentation.make(from: error)

        XCTAssertEqual(presentation, .network)
        XCTAssertTrue(presentation.showsRetry)
        XCTAssertFalse(presentation.isTargetGone)
    }

    func test_otherRejectedError_fallsBackToGenericRetryablePresentation() {
        let error = AppError.rejected(message: "未登入", code: "42501")

        let presentation = CommentsErrorPresentation.make(from: error)

        XCTAssertTrue(presentation.showsRetry)
        XCTAssertFalse(presentation.isTargetGone)
        XCTAssertEqual(presentation.message, error.userFacingMessage)
    }

    /// Mutation guard：拿掉 LS026 判斷會讓 targetFamilyMismatch 掉進「其餘錯誤」分支，變成
    /// 可重試——這條測試在正確實作下應為綠。
    func test_mutationGuard_targetFamilyMismatchNeverShowsRetry() {
        let error = AppError.rejected(message: "target 屬於別的家庭", code: LSErrorCode.targetFamilyMismatch.rawValue)

        XCTAssertFalse(CommentsErrorPresentation.make(from: error).showsRetry)
    }
}
