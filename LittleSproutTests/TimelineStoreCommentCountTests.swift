import Foundation
@testable import LittleSprout
import XCTest

/// LS-243：`TimelineStore` 初始化 `commentCounts` 讀 `get_family_timeline` 回傳的
/// `comment_count`。跟 `TimelineStoreTests` 是同一個測試對象，拆成獨立檔案純粹是為了
/// SwiftLint `type_body_length`（同 `TimelineStoreDeleteDiaryTests.swift`／
/// `TimelineStoreVideoTests.swift` 的既有拆檔理由與寫法）。
@MainActor
extension TimelineStoreTests {
    /// 還沒開過留言 sheet（沒呼叫過 `setCommentCount`）——互動列的留言鈕不該恆顯示 0，
    /// `refresh` 完成後就該直接讀伺服器這一頁回應帶的 `comment_count`（LS-216 票文
    /// scope 2 的既有缺口，見 `TimelineStore.commentCounts` 文件註解）。
    func test_refresh_populatesCommentCountsFromServer_beforeAnySheetOpened() async {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .media, refId: refId, occurredAt: Date(), childIds: [], commentCount: 5)]
        }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: UUID(), childID: nil)

        XCTAssertEqual(
            store.commentCount(forKey: TimelineEntry.id(kind: .media, refId: refId)), 5,
            "還沒開過留言 sheet（沒呼叫過 setCommentCount）—— comment_count 該直接來自伺服器這一頁的回應"
        )
    }
}
