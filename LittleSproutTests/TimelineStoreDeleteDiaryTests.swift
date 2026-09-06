import Foundation
@testable import LittleSprout
import XCTest

/// LS-190：`TimelineStore.removeDiaryEntryLocally`。跟 `TimelineStoreTests` 是同一個測試對象，
/// 拆成獨立檔案純粹是為了 SwiftLint `type_body_length`（同 `TimelineStoreVideoTests.swift` 的
/// 既有拆檔理由與寫法）。
@MainActor
extension TimelineStoreTests {
    /// 「刪除後狀態」票文驗收：成功刪除日記後，本地 `entries` 立即移除該篇，不等下一次
    /// `refresh()`；同陣列裡非日記種類（`.media`）的其他項目不受影響。
    func test_removeDiaryEntryLocally_removesOnlyMatchingDiaryEntry() {
        let store = TimelineStore(apiClient: StubTimelineAPIClient())
        let targetDiaryID = UUID()
        let otherDiaryID = UUID()
        let mediaID = UUID()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: targetDiaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(body: "要刪除的日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0))
            ),
            TimelineEntry(
                kind: .diary, refId: otherDiaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(body: "另一篇日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0))
            ),
            TimelineEntry(kind: .media, refId: mediaID, occurredAt: Date(), childIds: [], content: nil)
        ])

        store.removeDiaryEntryLocally(diaryID: targetDiaryID)

        XCTAssertEqual(store.entries.map(\.refId), [otherDiaryID, mediaID])
    }

    func test_removeDiaryEntryLocally_unknownID_isNoOp() {
        let store = TimelineStore(apiClient: StubTimelineAPIClient())
        let diaryID = UUID()
        store.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(body: "日記", entryDate: Date(), previewPhotos: [], totalPhotoCount: 0))
            )
        ])

        store.removeDiaryEntryLocally(diaryID: UUID())

        XCTAssertEqual(store.entries.count, 1)
    }
}
