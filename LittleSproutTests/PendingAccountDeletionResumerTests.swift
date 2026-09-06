import Foundation
@testable import LittleSprout
import XCTest

/// LS-193 merge-review R2 B2：`PendingAccountDeletionResumer`——`finalizeAccountDeletion()`
/// 續傳呼叫的唯一擁有者，`resumeIfPending(userID:)` 需要跨呼叫端（`AuthenticatedGate`／
/// `DeleteAccountFlowView.task`／`ForkView`「重試刪除」）去重，同一個 `userID` 同時只能有
/// 一個真正在飛的呼叫——這是 B2 修法的核心，獨立成自己的測試檔案。
@MainActor
final class PendingAccountDeletionResumerTests: XCTestCase {
    func test_resumeIfPending_noFlag_doesNothing() async {
        let userID = UUID()
        let stub = StubAccountAPIClient()
        let resumer = PendingAccountDeletionResumer(accountAPIClient: stub)

        resumer.resumeIfPending(userID: userID)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(stub.finalizeCallCount, 0)
        XCTAssertEqual(resumer.state, .idle)
    }

    func test_resumeIfPending_flagSet_callsFinalizeOnce_andClearsFlagOnSuccess() async {
        let userID = UUID()
        defer { PendingAccountDeletion.clear(userID: userID) }
        PendingAccountDeletion.markPending(userID: userID)
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler {}
        let resumer = PendingAccountDeletionResumer(accountAPIClient: stub)

        resumer.resumeIfPending(userID: userID)
        let met = await waitUntilResumerState(resumer, equals: .completed)

        XCTAssertTrue(met, "等待續傳完成逾時（1 秒）")
        XCTAssertEqual(stub.finalizeCallCount, 1)
        XCTAssertFalse(PendingAccountDeletion.isPending(userID: userID))
    }

    /// **B2 核心釘樁**：這支測試證明「跨呼叫端去重」真的成立——`AuthenticatedGate` 與
    /// `DeleteAccountFlowView.task` 可能幾乎同時對同一個 `userID` 呼叫
    /// `resumeIfPending`（例如登入完成的同一刻剛好畫面也進場），必須只有一個真正在飛的
    /// `finalizeAccountDeletion()` 呼叫。
    func test_resumeIfPending_calledTwiceBeforeFirstCompletes_onlyCallsFinalizeOnce() async {
        let userID = UUID()
        defer { PendingAccountDeletion.clear(userID: userID) }
        PendingAccountDeletion.markPending(userID: userID)
        let stub = StubAccountAPIClient()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFinalizeHandler {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        let resumer = PendingAccountDeletionResumer(accountAPIClient: stub)

        resumer.resumeIfPending(userID: userID)
        resumer.resumeIfPending(userID: userID) // 同一個 userID，第一個呼叫還沒完成

        // 等的是「`finalizeAccountDeletion()` 真的被呼叫過」，不是 `resumer.state ==
        // .inProgress`——後者在 `resumeIfPending` 回傳前就同步設好了，跟 `Task` 真正排到、
        // 執行到呼叫 `accountAPIClient.finalizeAccountDeletion()` 之間有時間差，等 `state`
        // 會在那個呼叫真的發生之前就通過，量不出「呼叫了幾次」。
        let called = await waitUntilFinalizeCalled(stub)
        XCTAssertTrue(called, "等待 finalizeAccountDeletion() 被呼叫逾時（1 秒）")
        XCTAssertEqual(stub.finalizeCallCount, 1, "同一個 userID 在飛中不該重複呼叫 finalizeAccountDeletion()")

        gateContinuation.finish()
    }

    private func waitUntilFinalizeCalled(_ stub: StubAccountAPIClient) async -> Bool {
        var iterations = 0
        while stub.finalizeCallCount < 1 {
            iterations += 1
            guard iterations < 200 else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func waitUntilResumerState(
        _ resumer: PendingAccountDeletionResumer, equals expected: PendingAccountDeletionResumer.State
    ) async -> Bool {
        var iterations = 0
        while resumer.state != expected {
            iterations += 1
            guard iterations < 200 else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
