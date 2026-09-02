import Foundation
@testable import LittleSprout
import XCTest

/// 建構 `TimelineFeedPointer` 樣本——刻意是**不掛 actor 隔離的自由函式**，不是
/// `TimelineStoreTests` 的實例方法：後者是 `@MainActor`，實例方法會被自動隔離，
/// 在 stub 的 `@Sendable` handler 閉包裡呼叫會同時觸發「跨 actor 需要 await」與
/// 「閉包捕捉非 Sendable 的 self」兩個編譯錯誤。
private func timelinePointer(refId: UUID, occurredAt: Date) -> TimelineFeedPointer {
    TimelineFeedPointer(kind: .media, refId: refId, occurredAt: occurredAt, childIds: [])
}

@MainActor
final class TimelineStoreTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let childID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func test_refresh_success_populatesEntriesAndHasMorePages() async {
        let stub = StubTimelineAPIClient()
        let pointers = (0..<TimelineStore.pageSize).map { index in
            timelinePointer(refId: UUID(), occurredAt: Date().addingTimeInterval(TimeInterval(-index)))
        }
        stub.setFetchPointersHandler { _, _, _, _ in pointers }
        let store = TimelineStore(apiClient: stub)

        let success = await store.refresh(familyID: familyID, childID: nil)

        XCTAssertTrue(success)
        XCTAssertEqual(store.entries.count, TimelineStore.pageSize)
        // 滿一頁（等於 pageSize）＝可能還有下一頁；未滿一頁才代表已到底。
        XCTAssertTrue(store.hasMorePages)
        XCTAssertEqual(store.refreshState, .success)
    }

    func test_refresh_partialPage_setsHasMorePagesFalse() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [timelinePointer(refId: UUID(), occurredAt: Date())] }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: nil)

        XCTAssertFalse(store.hasMorePages)
    }

    func test_refresh_failure_setsFailureState() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = TimelineStore(apiClient: stub)

        let success = await store.refresh(familyID: familyID, childID: nil)

        XCTAssertFalse(success)
        guard case .failure = store.refreshState else {
            return XCTFail("預期 refreshState 為 .failure，實際是 \(store.refreshState)")
        }
    }

    func test_refresh_passesChildIDThrough() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: childID)

        XCTAssertEqual(stub.fetchPointersCalls.last?.childID, childID)
        XCTAssertNil(stub.fetchPointersCalls.last?.cursor, "第一頁不應帶游標")
    }

    func test_loadMore_usesLastEntryAsCursor_andAppends() async {
        let stub = StubTimelineAPIClient()
        let firstPageID = UUID()
        let firstPageDate = Date().addingTimeInterval(-100)
        // 第一頁必須滿一頁（pageSize 筆）：`hasMorePages` 是用「這頁筆數是否等於 pageSize」
        // 判斷的（見 TimelineStore.refresh 文件），只回 1 筆會被判定為已到底，
        // `loadMore()` 會被 `guard hasMorePages` 直接擋下，測不到游標組裝邏輯。
        let firstPage = (0..<(TimelineStore.pageSize - 1)).map { index in
            timelinePointer(refId: UUID(), occurredAt: firstPageDate.addingTimeInterval(TimeInterval(index + 1)))
        } + [timelinePointer(refId: firstPageID, occurredAt: firstPageDate)]
        stub.setFetchPointersHandler { _, _, cursor, _ in cursor == nil ? firstPage : [] }
        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertEqual(store.entries.count, TimelineStore.pageSize)
        XCTAssertTrue(store.hasMorePages)

        let secondPageID = UUID()
        stub.setFetchPointersHandler { _, _, cursor, _ in
            guard let cursor else { return [] }
            XCTAssertEqual(cursor.refId, firstPageID)
            let expected = firstPageDate.timeIntervalSince1970
            XCTAssertEqual(cursor.occurredAt.timeIntervalSince1970, expected, accuracy: 0.001)
            return [timelinePointer(refId: secondPageID, occurredAt: firstPageDate.addingTimeInterval(-100))]
        }

        let success = await store.loadMore()

        XCTAssertTrue(success)
        XCTAssertEqual(store.entries.count, TimelineStore.pageSize + 1)
        XCTAssertEqual(store.entries.last?.refId, secondPageID)
    }

    func test_loadMore_whenNoMorePages_doesNothing() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [timelinePointer(refId: UUID(), occurredAt: Date())] }
        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil) // 未滿一頁 → hasMorePages=false

        let success = await store.loadMore()

        XCTAssertFalse(success)
        XCTAssertEqual(store.entries.count, 1, "不該多打一次請求把重複資料接進來")
    }

    func test_refresh_whileAlreadySubmitting_secondCallIsIgnored() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        stub.setFetchPointersHandler { _, _, _, _ in
            await gate.wait() // 卡住直到測試主動放行，模擬「還在 in-flight」。
            return []
        }
        let store = TimelineStore(apiClient: stub)

        let firstCall = Task { await store.refresh(familyID: familyID, childID: nil) }
        // 讓第一次呼叫先進到 submitting 狀態再發第二次——用短暫的 yield 而不是 sleep，
        // 因為第一次呼叫會卡在 gate.wait() 直到我們呼叫 gate.open()。
        while store.refreshState != .submitting { await Task.yield() }

        let secondResult = await store.refresh(familyID: familyID, childID: nil)
        XCTAssertFalse(secondResult, "同一個 store 正在 submitting 時，第二次呼叫應該直接被擋下")

        await gate.open()
        _ = await firstCall.value

        XCTAssertEqual(stub.fetchPointersCalls.count, 1, "被擋下的第二次呼叫不應該真的發出請求")
    }

    func test_reset_clearsAllState() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [timelinePointer(refId: UUID(), occurredAt: Date())] }
        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertFalse(store.entries.isEmpty)

        store.reset()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.refreshState, .idle)
        XCTAssertTrue(store.hasMorePages)
    }
}

/// 單次開關的非同步閘門，讓 `test_refresh_whileAlreadySubmitting_secondCallIsIgnored` 的 stub
/// handler 可以卡在「還在 in-flight」直到測試主動放行——用 actor 包住
/// `CheckedContinuation`，不用 `AsyncStream.AsyncIterator`（那是 mutating struct，跨
/// suspension point 呼叫其 async 方法在 Swift 6 嚴格併發下另有麻煩）。
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
