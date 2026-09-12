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

    // MARK: - syncCommentCountIfKnown（LS-237 修，池 `d17bed11` i4）

    @MainActor
    private func makeCommentsSheetView(timelineStore: TimelineStore) -> CommentsSheetView {
        CommentsSheetView(
            kind: .diary, refId: UUID(), familyID: UUID(), timelineStore: timelineStore,
            familyStore: .preview(), childrenStore: .preview(),
            commentAPIClient: StubCommentAPIClient(), safetyAPIClient: PreviewSafetyAPIClient()
        )
    }

    /// `sendTapped()` 送出成功後改呼叫這支方法，不再單靠 `.onChange(of: store.knownExactCount)`
    /// ——那個 modifier 掛在 `body`，sheet 若在送出仍在飛行中被關閉就不會再觸發。這裡完全不
    /// 把 `CommentsSheetView` 安裝到任何畫面／view 階層上，直接呼叫，證明這條回寫路徑不倚賴
    /// View 是否還掛在畫面上——`timelineStore` 是建構時傳入的長生命週期物件，呼叫端（
    /// `TimelineView+Comments`）跟這支 View 共用同一個實例。
    @MainActor
    func test_syncCommentCountIfKnown_hasEarlierFalse_writesCountToTimelineStore() {
        let timelineStore = TimelineStore.preview()
        let view = makeCommentsSheetView(timelineStore: timelineStore)
        view.store.seedForPreview([
            CommentRecord(id: UUID(), authorID: UUID(), authorDisplayName: "陳志明", body: "1", createdAt: Date()),
            CommentRecord(id: UUID(), authorID: UUID(), authorDisplayName: "林美玲", body: "2", createdAt: Date())
        ])

        view.syncCommentCountIfKnown()

        XCTAssertEqual(
            timelineStore.commentCount(forKey: view.targetKey), 2,
            "knownExactCount 非 nil（hasEarlier == false）時應該原樣寫進 timelineStore"
        )
    }

    /// `hasEarlier == true` 時 `knownExactCount` 是 `nil`（清單只是「至少這麼多」，不是總數）
    /// ——不該把不確定的數字寫進互動列，`timelineStore` 應該維持呼叫前的既有值（預設 0）。
    @MainActor
    func test_syncCommentCountIfKnown_hasEarlierTrue_doesNotWriteToTimelineStore() {
        let timelineStore = TimelineStore.preview()
        let view = makeCommentsSheetView(timelineStore: timelineStore)
        // 預設狀態：`hasEarlier` 初值就是 `true`，不需要額外種子。

        view.syncCommentCountIfKnown()

        XCTAssertEqual(
            timelineStore.commentCount(forKey: view.targetKey), 0,
            "knownExactCount 為 nil 時不該寫入，互動列應該維持既有值（預設 0）不受影響"
        )
    }
}
