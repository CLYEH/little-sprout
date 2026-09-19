import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-319（LS-249 4/4）：`MediaChildrenMarkingTracker`——批次匯入「指定寶貝」上傳完成後標記。
/// 直接對追蹤器發事件（`beginGroup`／`registerEntry`／`finishRegisteringGroup`／
/// `handleUploadSucceeded`／`handleUploadFailedTerminal`），不經過真正的 `PHAsset`／
/// `UploadQueueStore` 管線（同 `AlbumImportUploadCoordinatorTests` 檔頭「只驗證 coordinator
/// 自己的邏輯」的理由，這裡只驗證追蹤器自己的邏輯）。
@MainActor
final class MediaChildrenMarkingTrackerTests: XCTestCase {
    private func waitUntil(
        timeoutSeconds: Double = 1, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                return XCTFail("等待條件成立逾時", file: file, line: line)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 全部成功 → 呼叫一次 batch，帶正確的 media/child 集合，並觸發 onMarked

    func test_group_allSucceed_callsBatchOnceWithMediaIDsAndBabyIDs_andTriggersOnMarked() async {
        let apiStub = StubAlbumsAPIClient()
        let onMarkedCount = OSAllocatedUnfairLock(initialState: 0)
        let tracker = MediaChildrenMarkingTracker(
            apiClient: apiStub, onMarked: { onMarkedCount.withLock { $0 += 1 } }
        )
        let babyA = UUID()
        let babyB = UUID()
        let key = MediaChildrenMarkingTracker.GroupKey()
        let entryIDs = [UUID(), UUID(), UUID()]
        let mediaIDs = [UUID(), UUID(), UUID()]

        tracker.beginGroup(key, babyIDs: [babyA, babyB])
        for entryID in entryIDs { tracker.registerEntry(key, entryID: entryID) }
        tracker.finishRegisteringGroup(key)
        for (entryID, mediaID) in zip(entryIDs, mediaIDs) {
            tracker.handleUploadSucceeded(entryID: entryID, mediaID: mediaID)
        }

        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 1 }
        let call = apiStub.setMediaChildrenBatchCalls[0]
        XCTAssertEqual(Set(call.items.map(\.mediaID)), Set(mediaIDs), "批次要含這一群全部成功的 media")
        XCTAssertTrue(call.items.allSatisfy { $0.childIDs == [babyA, babyB] }, "每一筆都要帶這一群的 babyIDs")
        await waitUntil { onMarkedCount.withLock { $0 } == 1 }
        XCTAssertEqual(tracker.failedMarkingMediaCount(in: Set(entryIDs)), 0, "全部標記成功，不該有失敗計數")
    }

    // MARK: - 票文範圍 1：babyIDs 為空的群完全不呼叫（coordinator 端不會呼叫 beginGroup，這裡
    // 驗證追蹤器對「從沒 beginGroup 過的 key」的 registerEntry／finishRegisteringGroup 是 no-op，
    // 不會意外自己生出一個群）

    func test_registerEntry_withoutBeginGroup_isNoOp_neverCallsBatch() async {
        let apiStub = StubAlbumsAPIClient()
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let key = MediaChildrenMarkingTracker.GroupKey()
        let entryID = UUID()

        // 故意不呼叫 beginGroup（模擬 coordinator 對 babyIDs 為空的群完全不呼叫這三支）。
        tracker.registerEntry(key, entryID: entryID)
        tracker.finishRegisteringGroup(key)
        tracker.handleUploadSucceeded(entryID: entryID, mediaID: UUID())

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(apiStub.setMediaChildrenBatchCalls.isEmpty, "沒有 beginGroup 過的群不該觸發任何標記 RPC")
    }

    // MARK: - 批次拆分：501 → 2 批（500＋1）

    func test_group_over500SucceededMedia_splitsIntoTwoBatchCalls() async {
        let apiStub = StubAlbumsAPIClient()
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let key = MediaChildrenMarkingTracker.GroupKey()
        let babyID = UUID()
        let entryIDs = (0..<501).map { _ in UUID() }
        let mediaIDs = (0..<501).map { _ in UUID() }

        tracker.beginGroup(key, babyIDs: [babyID])
        for entryID in entryIDs { tracker.registerEntry(key, entryID: entryID) }
        tracker.finishRegisteringGroup(key)
        for (entryID, mediaID) in zip(entryIDs, mediaIDs) {
            tracker.handleUploadSucceeded(entryID: entryID, mediaID: mediaID)
        }

        await waitUntil(timeoutSeconds: 3) { apiStub.setMediaChildrenBatchCalls.count == 2 }
        let sizes = apiStub.setMediaChildrenBatchCalls.map { $0.items.count }.sorted()
        XCTAssertEqual(sizes, [1, 500], "501 筆要拆成 500＋1 兩批，不是一次全送或拆成別的比例")
        let allSentMediaIDs = apiStub.setMediaChildrenBatchCalls.flatMap { $0.items.map(\.mediaID) }
        XCTAssertEqual(Set(allSentMediaIDs), Set(mediaIDs), "兩批合起來要覆蓋全部 501 筆，沒有漏或重複")
    }

    // MARK: - 兩條 deny 路徑：標記失敗計入摘要／上傳失敗不計入標記失敗

    /// deny 路徑 1：標記 RPC 本身失敗（例如撞到 23503／LS044）——要計入
    /// `failedMarkingMediaCount(in:)`，不能靜默吞掉。
    func test_markingRPCFails_countsAsFailedMarking_notSilentlySwallowed() async {
        let apiStub = StubAlbumsAPIClient()
        apiStub.setSetMediaChildrenBatchHandler { _ in
            throw AppError.validationRetryable(message: "跨家庭 child", code: "23503")
        }
        let onMarkedCount = OSAllocatedUnfairLock(initialState: 0)
        let tracker = MediaChildrenMarkingTracker(
            apiClient: apiStub, onMarked: { onMarkedCount.withLock { $0 += 1 } }
        )
        let key = MediaChildrenMarkingTracker.GroupKey()
        let entryID = UUID()

        tracker.beginGroup(key, babyIDs: [UUID()])
        tracker.registerEntry(key, entryID: entryID)
        tracker.finishRegisteringGroup(key)
        tracker.handleUploadSucceeded(entryID: entryID, mediaID: UUID())

        await waitUntil { tracker.failedMarkingMediaCount(in: [entryID]) == 1 }
        XCTAssertEqual(onMarkedCount.withLock { $0 }, 0, "標記失敗不該觸發時間軸刷新")
    }

    /// deny 路徑 2：上傳本身終局失敗（從未成功、從未呼叫 RPC）——不能被算進「標記未完成」，
    /// 這是兩件不同的事（票文範圍 2：「不影響上傳成功數」，也不該汙染標記失敗計數）。
    func test_uploadTerminalFailure_neverCallsBatch_doesNotCountAsMarkingFailure() async {
        let apiStub = StubAlbumsAPIClient()
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let key = MediaChildrenMarkingTracker.GroupKey()
        let entryID = UUID()

        tracker.beginGroup(key, babyIDs: [UUID()])
        tracker.registerEntry(key, entryID: entryID)
        tracker.finishRegisteringGroup(key)
        tracker.handleUploadFailedTerminal(entryID: entryID)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(apiStub.setMediaChildrenBatchCalls.isEmpty, "整群都沒有成功上傳的，不該呼叫標記 RPC")
        XCTAssertEqual(
            tracker.failedMarkingMediaCount(in: [entryID]), 0, "上傳失敗不是標記失敗，不該算進「N 張寶貝標記未完成」"
        )
    }

    // MARK: - 群內部分失敗：只標記成功的子集

    func test_partialUploadFailureInGroup_marksOnlySucceededSubset() async {
        let apiStub = StubAlbumsAPIClient()
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let key = MediaChildrenMarkingTracker.GroupKey()
        let succeededEntry = UUID()
        let failedEntry = UUID()
        let mediaID = UUID()

        tracker.beginGroup(key, babyIDs: [UUID()])
        tracker.registerEntry(key, entryID: succeededEntry)
        tracker.registerEntry(key, entryID: failedEntry)
        tracker.finishRegisteringGroup(key)
        tracker.handleUploadSucceeded(entryID: succeededEntry, mediaID: mediaID)
        tracker.handleUploadFailedTerminal(entryID: failedEntry)

        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 1 }
        XCTAssertEqual(apiStub.setMediaChildrenBatchCalls[0].items.map(\.mediaID), [mediaID])
    }

    // MARK: - 「重試標記」只重送失敗群

    func test_retryFailedMarking_onlyResendsFailedGroup_notSucceededGroup() async {
        let apiStub = StubAlbumsAPIClient()
        let shouldFail = OSAllocatedUnfairLock(initialState: true)
        apiStub.setSetMediaChildrenBatchHandler { _ in
            if shouldFail.withLock({ $0 }) {
                throw AppError.rejected(message: "已軟刪孩子", code: "LS044")
            }
        }
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let failingKey = MediaChildrenMarkingTracker.GroupKey()
        let succeedingKey = MediaChildrenMarkingTracker.GroupKey()
        let failingEntry = UUID()
        let succeedingEntry = UUID()

        tracker.beginGroup(failingKey, babyIDs: [UUID()])
        tracker.registerEntry(failingKey, entryID: failingEntry)
        tracker.finishRegisteringGroup(failingKey)
        tracker.handleUploadSucceeded(entryID: failingEntry, mediaID: UUID())
        await waitUntil { tracker.failedMarkingMediaCount(in: [failingEntry]) == 1 }

        shouldFail.withLock { $0 = false }
        tracker.beginGroup(succeedingKey, babyIDs: [UUID()])
        tracker.registerEntry(succeedingKey, entryID: succeedingEntry)
        tracker.finishRegisteringGroup(succeedingKey)
        tracker.handleUploadSucceeded(entryID: succeedingEntry, mediaID: UUID())
        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 2 }

        tracker.retryFailedMarking(in: [failingEntry, succeedingEntry])

        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 3 }
        XCTAssertEqual(tracker.failedMarkingMediaCount(in: [failingEntry]), 0, "重試成功後失敗計數要歸零")
        // 只有原本失敗的那一群被重送——第三次呼叫仍是那一筆 entry 對應的 media，不是把已成功
        // 的群也重送一次（呼叫次數固定在 3：第一次失敗、第二次成功、第三次重試，不是 4）。
    }
}
