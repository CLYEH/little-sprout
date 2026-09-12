@testable import LittleSprout
import XCTest

/// LS-218 merge-review R1 m1：`CommentsSheetView.headCommentCountText(...)`——抽成靜態純函式
/// 方便單元測試（同 `CommentsErrorPresentation.make(from:)` 既有慣例），不依賴 View 就能測分岔。
final class CommentsSheetViewTests: XCTestCase {
    func test_headCommentCountText_beforeSuccess_showsFullWidthSpacePlaceholder() {
        for state: CommentsOperationState in [.idle, .submitting, .failure(.network(message: "offline"))] {
            let text = CommentsSheetView.headCommentCountText(
                initialLoadState: state, commentCount: 3, hasEarlier: false
            )
            XCTAssertEqual(text, "\u{3000}", "載入完成前／失敗時顯示筆數沒有意義，應該用全形空白佔位保留高度")
        }
    }

    func test_headCommentCountText_success_hasEarlierFalse_showsExactCount() {
        let text = CommentsSheetView.headCommentCountText(
            initialLoadState: .success, commentCount: 3, hasEarlier: false
        )
        XCTAssertEqual(text, "3 則留言", "清單已載到底，comments.count 就是確定總數，不該加「+」")
    }

    /// merge-review R1 m1：分頁時 `comments.count` 只是「至少這麼多」，不是總數——Head 用
    /// 「+」誠實標示不確定（sheet 內部使用者能直接看到清單佐證，不會誤導）。
    func test_headCommentCountText_success_hasEarlierTrue_showsPlusSuffix() {
        let text = CommentsSheetView.headCommentCountText(
            initialLoadState: .success, commentCount: 20, hasEarlier: true
        )
        XCTAssertEqual(text, "20+ 則留言", "hasEarlier 為 true 時應該用「+」標示這只是已載入筆數、不是總數")
    }
}
