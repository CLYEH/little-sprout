import Foundation
@testable import LittleSprout
import XCTest

/// LS-329 R2（merge-review R1 M1，comment `b993ab2d`）：一整頁（`TimelineStore.pageSize`
/// 筆）全是未知 kind（例如 LS-325 `food_first`）不該讓時間軸卡在空狀態或 `loadMore`
/// 原地踏步。跟 `TimelineStoreTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `file_length`（同 `TimelineStoreVideoTests.swift`／`TimelineStoreRefreshDedupTests.swift`
/// 的既有拆檔理由與寫法；`TimelineStoreTests.swift` 本身已接近 400 行上限，加上去會撞
/// `file_length`）。
///
/// 為什麼這兩支測試重要：舊版 app（尚未升級到認得新 kind 的版本）遇到別人用新版 app
/// 補登的資料時，`assemble` 會把認不得的 kind 濾掉——這是正確行為（見 LS-329 R1）。但
/// 濾掉之後 pointer→entry 不再 1:1，若整頁剛好全是未知 kind，天真的分頁邏輯會誤判成
/// 「這頁沒有更舊的內容了」（`entries` 為空、`entries.last` 拿不到游標），讓舊版 app
/// 使用者看到自己的日記／相簿／照片時間軸整頁消失，或捲到底卡死——這正是本票標題要
/// 避免的狀況，比「單純顯示不出新 kind 那一筆」嚴重得多。
@MainActor
extension TimelineStoreTests {
    /// 第一頁（pageSize 筆）全是未知 kind（例如家長一次用新版 app 補登 ≥20 種「已吃過」的
    /// 食物，LS-325 `food_first` 用 `first_tried_on` 當 `occurred_at`）——尚未升級的舊版
    /// app 這批全解不出內容。若沒有 `TimelineContentAssembler.fetchAssembledPage` 續抓
    /// 邏輯，`assemble` 濾掉後只剩空陣列，`entries` 會是空的、`entries.last` 也拿不到游標，
    /// 較舊的已知內容（日記／相簿／照片）永遠翻不到——時間軸就停在本票標題要避免的「整頁
    /// 空」。舊版 app 不該因為別人補登的新 kind 資料而看不到自己的回憶。
    func test_refresh_firstPageAllUnknownKinds_stillReachesOlderKnownEntry() async {
        let familyID = UUID()
        let stub = StubTimelineAPIClient()
        let base = Date()
        let unknownPage = (0..<TimelineStore.pageSize).map { index in
            TimelineFeedPointer(
                kind: .unknown("food_first"), refId: UUID(),
                occurredAt: base.addingTimeInterval(TimeInterval(-index)), childIds: []
            )
        }
        let olderKnownID = UUID()
        stub.setFetchPointersHandler { _, _, cursor, _ in
            guard cursor != nil else { return unknownPage }
            return [
                TimelineFeedPointer(
                    kind: .media, refId: olderKnownID,
                    occurredAt: base.addingTimeInterval(-3600), childIds: []
                )
            ]
        }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: nil)
        await store.loadMore()

        XCTAssertEqual(
            store.entries.map(\.refId), [olderKnownID],
            "第一頁全是未知 kind 時，較舊的已知內容不該拿不到——時間軸不能停在空狀態"
        )
    }

    /// `loadMore` 撞上一整頁（pageSize 筆）未知 kind——游標必須越過這批繼續往下翻，不能
    /// 用「這頁沒有新 entries 可 append」就誤判成已到底，也不能讓下一次 `loadMore` 帶著
    /// 同一個游標原地踏步（使用者會看到底部轉圈卡死，捲不到更舊的內容）。
    func test_loadMore_pageAllUnknownKinds_cursorAdvancesPastThemToOlderKnownEntry() async {
        let familyID = UUID()
        let stub = StubTimelineAPIClient()
        let base = Date()
        let firstPage = (0..<TimelineStore.pageSize).map { index in
            TimelineFeedPointer(
                kind: .media, refId: UUID(), occurredAt: base.addingTimeInterval(TimeInterval(-index)), childIds: []
            )
        }
        let lastKnown = firstPage[firstPage.count - 1]
        let unknownRun = (0..<TimelineStore.pageSize).map { index in
            TimelineFeedPointer(
                kind: .unknown("food_first"), refId: UUID(),
                occurredAt: lastKnown.occurredAt.addingTimeInterval(TimeInterval(-10 - index)), childIds: []
            )
        }
        let lastUnknownID = unknownRun[unknownRun.count - 1].refId
        let olderKnownID = UUID()
        stub.setFetchPointersHandler { _, _, cursor, _ in
            guard let cursor else { return firstPage }
            if cursor.refId == lastKnown.refId { return unknownRun }
            if cursor.refId == lastUnknownID {
                return [
                    TimelineFeedPointer(
                        kind: .media, refId: olderKnownID,
                        occurredAt: base.addingTimeInterval(-3600), childIds: []
                    )
                ]
            }
            return []
        }
        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)

        await store.loadMore()
        await store.loadMore()

        let cursors = stub.fetchPointersCalls.compactMap(\.cursor).map(\.refId)
        XCTAssertFalse(
            cursors.count >= 2 && cursors[0] == cursors[1], "loadMore 兩次用同一個游標（原地踏步）：\(cursors)"
        )
        XCTAssertEqual(store.entries.last?.refId, olderKnownID, "一整頁未知 kind 之後的較舊內容永遠載不到")
    }
}
