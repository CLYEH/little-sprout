@testable import LittleSprout
import XCTest

final class DiaryDeleteConfirmationCopyTests: XCTestCase {
    func test_shortBody_notTruncated_matchesDesignExample() {
        // 稿面 `oFRMc` 範例逐字：「要刪除「今天在溜滑梯上玩得好開心。」這篇日記嗎？」。
        XCTAssertEqual(
            DiaryDeleteConfirmationCopy.title(forBody: "今天在溜滑梯上玩得好開心。"),
            "要刪除「今天在溜滑梯上玩得好開心。」這篇日記嗎？"
        )
    }

    func test_longBody_truncatedWithEllipsis() {
        let longBody = String(repeating: "字", count: 40)
        let excerpt = DiaryDeleteConfirmationCopy.excerpt(from: longBody)

        XCTAssertEqual(excerpt.count, DiaryDeleteConfirmationCopy.maxExcerptLength + 1, "截斷後應是上限字數＋一個刪節號")
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func test_multilineBody_collapsedToSingleLine() {
        let excerpt = DiaryDeleteConfirmationCopy.excerpt(from: "第一行\n第二行")

        XCTAssertEqual(excerpt, "第一行 第二行")
        XCTAssertFalse(excerpt.contains("\n"))
    }

    func test_leadingAndTrailingWhitespace_trimmed() {
        let excerpt = DiaryDeleteConfirmationCopy.excerpt(from: "  帶空白的內文  ")

        XCTAssertEqual(excerpt, "帶空白的內文")
    }
}
