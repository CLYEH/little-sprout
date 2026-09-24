import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-373 D5：「補上寶貝」進行中狀態——按下後到 RPC 回來前，05 的統計子列與 Marking Section
/// 版面不動（`failedGroups` 保留）、按鈕停用＋「正在補上寶貝…」；成功後列與停用態一起消失，
/// 失敗則按鈕回到可按（Notes `x73Dy6`／`XG9yu`）。R1 版本按下即從 `failedGroups` 移除，列會
/// 瞬間消失、失敗再出現——這裡鎖住不再那樣。
@MainActor
final class MediaChildrenMarkingTrackerInFlightTests: XCTestCase {
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

    /// 第一次呼叫失敗（可重試），之後的呼叫卡住直到 `release` 設定結果——模擬「補上寶貝」
    /// 請求還在路上。
    private enum RetryOutcome { case pending, succeed, fail }

    private func makeTrackerWithRetryableFailure(
        entryID: UUID, outcome: OSAllocatedUnfairLock<RetryOutcome>
    ) async -> (MediaChildrenMarkingTracker, StubAlbumsAPIClient) {
        let apiStub = StubAlbumsAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        apiStub.setSetMediaChildrenBatchHandler { _ in
            let call = callCount.withLock { count -> Int in
                count += 1
                return count
            }
            if call == 1 { throw AppError.validationRetryable(message: "暫時失敗", code: "42501") }
            while outcome.withLock({ $0 }) == .pending {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if outcome.withLock({ $0 }) == .fail {
                throw AppError.validationRetryable(message: "又失敗", code: "42501")
            }
        }
        let tracker = MediaChildrenMarkingTracker(apiClient: apiStub, onMarked: {})
        let key = MediaChildrenMarkingTracker.GroupKey()
        tracker.beginGroup(key, babyIDs: [UUID()])
        tracker.registerEntry(key, entryID: entryID)
        tracker.finishRegisteringGroup(key)
        tracker.handleUploadSucceeded(entryID: entryID, mediaID: UUID())
        await waitUntil { tracker.failedMarkingMediaCount(in: [entryID]) == 1 }
        return (tracker, apiStub)
    }

    private func buttonTitle(_ tracker: MediaChildrenMarkingTracker, _ entryID: UUID) -> (String, Bool) {
        let presentation = Import05SummaryContent.fillBabiesButton(
            count: tracker.retryableFailedMarkingCount(in: [entryID]),
            isInFlight: tracker.isRetryingMarking(in: [entryID])
        )
        return (presentation.title, presentation.isDisabled)
    }

    func test_fillBabies_inFlight_keepsLayout_disablesButton_thenSuccessClearsBoth() async {
        let outcome = OSAllocatedUnfairLock(initialState: RetryOutcome.pending)
        let entryID = UUID()
        let (tracker, apiStub) = await makeTrackerWithRetryableFailure(entryID: entryID, outcome: outcome)
        XCTAssertEqual(buttonTitle(tracker, entryID).0, "補上寶貝\u{2060}（1）")
        XCTAssertFalse(buttonTitle(tracker, entryID).1)

        tracker.retryFailedMarking(in: [entryID])

        XCTAssertTrue(tracker.isRetryingMarking(in: [entryID]), "按下後立即進入進行中")
        XCTAssertEqual(
            tracker.failedMarkingMediaCount(in: [entryID]), 1,
            "進行中統計子列與 Marking Section 要留著（版面不動），不能按下就消失"
        )
        XCTAssertEqual(buttonTitle(tracker, entryID).0, "正在補上寶貝…")
        XCTAssertTrue(buttonTitle(tracker, entryID).1, "進行中按鈕停用")
        await waitUntil { apiStub.setMediaChildrenBatchCalls.count == 2 }

        tracker.retryFailedMarking(in: [entryID])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(apiStub.setMediaChildrenBatchCalls.count, 2, "進行中的群不重送（連點／重入）")

        outcome.withLock { $0 = .succeed }
        await waitUntil { !tracker.isRetryingMarking(in: [entryID]) }
        XCTAssertEqual(tracker.failedMarkingMediaCount(in: [entryID]), 0, "成功後統計子列與段落一起消失")
    }

    func test_fillBabies_inFlight_thenFailure_restoresEnabledButton() async {
        let outcome = OSAllocatedUnfairLock(initialState: RetryOutcome.pending)
        let entryID = UUID()
        let (tracker, _) = await makeTrackerWithRetryableFailure(entryID: entryID, outcome: outcome)

        tracker.retryFailedMarking(in: [entryID])
        XCTAssertTrue(buttonTitle(tracker, entryID).1)

        outcome.withLock { $0 = .fail }
        await waitUntil { !tracker.isRetryingMarking(in: [entryID]) }
        XCTAssertEqual(tracker.failedMarkingMediaCount(in: [entryID]), 1, "再失敗：列留著")
        XCTAssertEqual(buttonTitle(tracker, entryID).0, "補上寶貝\u{2060}（1）", "再失敗：按鈕回到可按、N 依剩下的群")
        XCTAssertFalse(buttonTitle(tracker, entryID).1)
    }
}
