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

    // MARK: - merge-review R1 M1／M2：generation token（換篩選中 refresh、refresh 中
    // loadMore 的結果丟棄）

    /// M1 核心場景：`ChildFilterBar` 換到新的 `childID` 時，第一頁還在飛——舊做法
    /// （`guard !refreshState.isSubmitting`）會讓新呼叫被舊呼叫擋下、連 `childID` 都沒被
    /// 記錄；新做法必須讓新呼叫立刻生效，且舊呼叫遲到的結果（不論成功或失敗）都不能覆寫。
    func test_refresh_secondCallWithDifferentChildID_winsOverStaleInFlightCall() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        let secondPageID = UUID()
        stub.setFetchPointersHandler { _, childID, _, _ in
            if childID == nil {
                await gate.wait() // 卡住直到測試主動放行，模擬「還在 in-flight」。
                // 舊做法會讓這個遲到的失敗被寫成 `.failure`，蓋掉新篩選已經成功的畫面
                // ——這正是 handoff 記的「切到陳小軒時畫面短暫全空」的成因（merge-review
                // R1 M1）。
                throw AppError.network(message: "cancelled")
            }
            return [timelinePointer(refId: secondPageID, occurredAt: Date())]
        }
        let store = TimelineStore(apiClient: stub)

        let firstCall = Task { await store.refresh(familyID: familyID, childID: nil) }
        while store.refreshState != .submitting { await Task.yield() }

        let newChildID = UUID()
        let secondSucceeded = await store.refresh(familyID: familyID, childID: newChildID)

        XCTAssertTrue(secondSucceeded, "換了 childID 的新呼叫不能被還在飛的舊呼叫擋下")
        XCTAssertEqual(store.entries.map(\.refId), [secondPageID], "應該是新篩選的結果，不是舊篩選")
        XCTAssertEqual(stub.fetchPointersCalls.last?.childID, newChildID, "新呼叫的參數必須被記錄並送出")

        await gate.open()
        _ = await firstCall.value

        XCTAssertEqual(
            store.entries.map(\.refId), [secondPageID], "舊呼叫遲到的結果不能覆寫新篩選已經寫回的資料"
        )
        XCTAssertEqual(store.refreshState, .success, "舊呼叫遲到的失敗不能把畫面狀態打回 .failure")
    }

    /// M2 核心場景：使用者捲到底觸發 `loadMore`，飛在半空時又觸發了一次 `refresh`（切篩選或
    /// 下拉更新）並先完成——`loadMore` 帶的游標是對舊 `entries` 基底算的，遲到回來時不能
    /// `append` 到已經被換掉的新列表後面（會跳項／混篩選／重複 id）。
    func test_loadMore_supersededByRefresh_discardsResultsAndResetsLoadMoreState() async {
        let stub = StubTimelineAPIClient()
        let firstPageLastID = UUID()
        let firstPageDate = Date().addingTimeInterval(-1000)
        let firstPage = (0..<(TimelineStore.pageSize - 1)).map { index in
            timelinePointer(refId: UUID(), occurredAt: firstPageDate.addingTimeInterval(TimeInterval(index + 1)))
        } + [timelinePointer(refId: firstPageLastID, occurredAt: firstPageDate)]
        stub.setFetchPointersHandler { _, _, cursor, _ in cursor == nil ? firstPage : [] }

        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertEqual(store.entries.count, TimelineStore.pageSize)
        XCTAssertTrue(store.hasMorePages)

        // 換 handler：`loadMore`（帶游標）卡住等訊號；期間的 `refresh`（無游標）立刻回一個
        // 可辨識的單筆結果，模擬「loadMore 還在飛時使用者切了篩選／下拉更新」。
        let gate = AsyncGate()
        let refreshedID = UUID()
        stub.setFetchPointersHandler { _, _, cursor, _ in
            guard cursor != nil else { return [timelinePointer(refId: refreshedID, occurredAt: Date())] }
            await gate.wait()
            return [timelinePointer(refId: UUID(), occurredAt: firstPageDate.addingTimeInterval(-2000))]
        }

        let loadMoreTask = Task { await store.loadMore() }
        while store.loadMoreState != .submitting { await Task.yield() }

        let refreshSucceeded = await store.refresh(familyID: familyID, childID: nil)
        XCTAssertTrue(refreshSucceeded)
        XCTAssertEqual(store.entries.map(\.refId), [refreshedID])

        await gate.open()
        let loadMoreSucceeded = await loadMoreTask.value

        XCTAssertFalse(loadMoreSucceeded, "被 refresh 取代的 loadMore 不該回報成功")
        XCTAssertEqual(
            store.entries.map(\.refId), [refreshedID], "loadMore 的遲到結果不能 append 到已經被換掉的新列表上"
        )
        XCTAssertEqual(
            store.loadMoreState, .idle, "loadMoreState 必須被收回非 submitting，不然下一次捲到底會被永久卡住"
        )
    }

    /// R2-M1 核心場景（R1 的世代號檢查漏掉的第三種交錯）：`refresh` 先開始（世代號先遞增）
    /// 且還沒完成時，`loadMore` 才起跑——兩者拿到**同一個**世代號。`refresh` 先完成、把
    /// `entries` 整批換掉；`loadMore` 用「舊 entries 尾端」算出的游標稍後才回來，此時單靠
    /// 世代號比對會誤判成「沒有被取代」（世代號確實沒變）而繼續 `append`，造成跳項／混
    /// 篩選／重複 id——必須額外釘住出發當下的尾端身分（`baseTailID`）才抓得到。拿掉
    /// `loadMore()` 寫回前的 `entries.last?.id == baseTailID` 檢查，本測試應該轉紅。
    func test_loadMore_startedDuringInFlightRefresh_discardsStaleResultsEvenWithSameGeneration() async {
        let stub = StubTimelineAPIClient()
        let oldLastID = UUID()
        let oldFirstPageDate = Date().addingTimeInterval(-1000)
        let oldFirstPage = (0..<(TimelineStore.pageSize - 1)).map { index in
            timelinePointer(refId: UUID(), occurredAt: oldFirstPageDate.addingTimeInterval(TimeInterval(index + 1)))
        } + [timelinePointer(refId: oldLastID, occurredAt: oldFirstPageDate)]
        stub.setFetchPointersHandler { _, _, cursor, _ in cursor == nil ? oldFirstPage : [] }

        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertTrue(store.hasMorePages)
        XCTAssertEqual(store.entries.last?.refId, oldLastID)

        // 換 handler：refresh（無游標）與 loadMore（帶「舊」游標）分別卡在各自的閘門，
        // 讓測試能精準控制「誰先完成」——本測試要的順序是 refresh 先完成、loadMore 晚到。
        let refreshGate = AsyncGate()
        let loadMoreGate = AsyncGate()
        let refreshedID = UUID()
        let staleLoadMoreID = UUID()
        stub.setFetchPointersHandler { _, _, cursor, _ in
            if cursor == nil {
                await refreshGate.wait()
                return [timelinePointer(refId: refreshedID, occurredAt: Date())]
            } else {
                await loadMoreGate.wait()
                return [timelinePointer(refId: staleLoadMoreID, occurredAt: oldFirstPageDate.addingTimeInterval(-2000))]
            }
        }

        // refresh 先開始（世代號先遞增），還卡在閘門裡。
        let refreshTask = Task { await store.refresh(familyID: familyID, childID: nil) }
        while store.refreshState != .submitting { await Task.yield() }

        // refresh 還沒完成時，loadMore 才起跑——此時 entries 仍是「舊」的一頁，
        // loadMore 在這裡捕捉到的 baseTailID 就是 oldLastID、世代號跟 refresh 相同。
        let loadMoreTask = Task { await store.loadMore() }
        while store.loadMoreState != .submitting { await Task.yield() }

        // 先放行 refresh：完成後 entries 整批換成 [refreshedID]。
        await refreshGate.open()
        _ = await refreshTask.value
        XCTAssertEqual(store.entries.map(\.refId), [refreshedID])

        // 再放行 loadMore：世代號沒變（跟 refresh 完成時同一個），但 entries 尾端已經不是
        // loadMore 出發時的 oldLastID，寫回前必須被擋下。
        await loadMoreGate.open()
        let loadMoreSucceeded = await loadMoreTask.value

        XCTAssertFalse(loadMoreSucceeded, "世代號相同但 entries 基底已經被換掉的 loadMore 不該回報成功")
        XCTAssertEqual(
            store.entries.map(\.refId), [refreshedID],
            "loadMore 用舊游標查到的結果不能 append 到已經被 refresh 換掉的新列表上，即使世代號一樣"
        )
        XCTAssertEqual(store.loadMoreState, .idle, "loadMoreState 必須被收回非 submitting，不然下一次捲到底會永久卡住")
    }

    /// 同參數重入仍然要擋（跟 M1「換參數」是不同情境，這條沒有變）。
    func test_loadMore_whileAlreadySubmitting_secondCallIsIgnored() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        let firstPageDate = Date().addingTimeInterval(-1000)
        // 初始 refresh 必須滿一頁，`hasMorePages` 才會是 true，`loadMore()` 才不會被
        // `guard hasMorePages` 提前擋下、測不到本測試要驗的 in-flight 重入 guard。
        let firstPage = (0..<TimelineStore.pageSize).map { index in
            timelinePointer(refId: UUID(), occurredAt: firstPageDate.addingTimeInterval(TimeInterval(index)))
        }
        stub.setFetchPointersHandler { _, _, cursor, _ in
            guard cursor != nil else { return firstPage }
            await gate.wait() // 卡住直到測試主動放行，模擬「loadMore 還在 in-flight」。
            return []
        }
        let store = TimelineStore(apiClient: stub)
        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertTrue(store.hasMorePages)

        let firstCall = Task { await store.loadMore() }
        while store.loadMoreState != .submitting { await Task.yield() }

        let secondResult = await store.loadMore()
        XCTAssertFalse(secondResult, "同一個 store 正在 loadMore submitting 時，第二次呼叫應該直接被擋下")

        await gate.open()
        _ = await firstCall.value

        // 初始 refresh 1 次＋loadMore 只有 1 次真正發出（第二次重入被擋）＝共 2 次。
        XCTAssertEqual(stub.fetchPointersCalls.count, 2, "被擋下的第二次 loadMore 不應該真的發出請求")
    }

    /// M5 相關防線：登出（`reset()`）時遞增世代號，上一個帳號還在飛的 `refresh` 遲到回來
    /// 不能把資料寫回已經清空的 store（見 `TimelineStore.reset()` 文件註解）。
    func test_reset_whileRefreshInFlight_lateResultsAreDiscarded() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        stub.setFetchPointersHandler { _, _, _, _ in
            await gate.wait()
            return [timelinePointer(refId: UUID(), occurredAt: Date())]
        }
        let store = TimelineStore(apiClient: stub)

        let refreshTask = Task { await store.refresh(familyID: familyID, childID: nil) }
        while store.refreshState != .submitting { await Task.yield() }

        store.reset()
        XCTAssertTrue(store.entries.isEmpty)

        await gate.open()
        _ = await refreshTask.value

        XCTAssertTrue(store.entries.isEmpty, "reset 後，登出前還在飛的 refresh 遲到的結果不能寫回")
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

    // LS-130 signFullSizeURL／R2-M1 loadVideoDuration 測試已搬到
    // `TimelineStoreVideoTests.swift`（extension，SwiftLint `type_body_length`／
    // `file_length` 拆檔，同 `OTPVerificationModelRateLimitTests.swift` 先例）。
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
