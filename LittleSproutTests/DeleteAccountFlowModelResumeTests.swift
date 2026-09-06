import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-193 merge-review R1 M3／R2 B2：`delete_my_account()` RPC 已成功、Edge Function 沒打完
/// （app 被殺掉／失敗）之後的續傳。跟 `DeleteAccountFlowModelTests` 是同一個測試對象，拆成獨立
/// 檔案同 `DeleteAccountFlowModelRaceTests.swift` 的既有理由——共用該檔的 `makeModel(...)`／
/// `waitUntil(...)` 測試工廠方法，額外需要一個「有 session」的 `authStub`。
///
/// **merge-review R2 B2 訂正**：`DeleteAccountFlowModel.init` 不再自己打 EF（見該檔文件
/// 註解）——這裡的測試因此明確呼叫 `model.resumeIfNeeded()` 模擬 `DeleteAccountFlowView.task`
/// 的角色，才能真的觸發 `PendingAccountDeletionResumer` 的 `Task`。`step` 在
/// `resumeIfNeeded()` 呼叫之前就已經同步反映本機旗標（見 `test
/// _step_pendingFlagSet_synchronouslyShowsInProgressBeforeResuming`），但不會有任何網路呼叫
/// 發生，直到真的呼叫 `resumeIfNeeded()`。
extension DeleteAccountFlowModelTests {
    /// 每支測試結束都清掉 `myID` 的旗標——`UserDefaults.standard` 是全域單例，不清會讓其他
    /// 用到同一個 `myID` 常數的測試（`DeleteAccountFlowModelTests` 主檔）誤讀到殘留狀態。
    private func makeResumableFixture(
        accountAPIClient: AccountAPIClient = StubAccountAPIClient()
    ) -> Fixture {
        PendingAccountDeletion.markPending(userID: myID)
        let session = AuthSession(userID: myID, email: "a@example.com", expiresAt: .distantFuture)
        return makeModel(accountAPIClient: accountAPIClient, authStub: StubAuthService(currentSession: session))
    }

    /// **merge-review R2 B2 核心釘樁**：本機旗標存在時，`step` 必須在 `resumeIfNeeded()` 被
    /// 呼叫**之前**就已經同步顯示 `.inProgress`（純讀 `UserDefaults`，不是網路 I/O，見
    /// `DeleteAccountFlowModel.step` 文件註解），但這個時候還沒有任何網路呼叫真的發生——
    /// `finalizeCallCount` 必須是 0。這證明「畫面不閃到三分流」與「init 不做 I/O」兩件事同時
    /// 成立，不是互斥的。
    func test_step_pendingFlagSet_synchronouslyShowsInProgress_withoutNetworkCall() {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        let fixture = makeResumableFixture(accountAPIClient: stub)

        XCTAssertEqual(fixture.model.step, .inProgress)
        XCTAssertEqual(stub.finalizeCallCount, 0, "還沒呼叫 resumeIfNeeded()，不該有任何網路呼叫")
    }

    func test_resumeIfNeeded_pendingFlagSet_doesNotCallDeleteMyAccountAgain_onlyFinalize() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler {}
        let fixture = makeResumableFixture(accountAPIClient: stub)

        fixture.model.resumeIfNeeded()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待續傳完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 0, "RPC 上次已經成功，續傳不該重打")
        XCTAssertEqual(stub.finalizeCallCount, 1)
    }

    func test_resumeIfNeeded_pendingFlagSet_finalizeSucceeds_clearsPendingFlag() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler {}
        let fixture = makeResumableFixture(accountAPIClient: stub)

        fixture.model.resumeIfNeeded()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待續傳完成逾時（1 秒）")

        XCTAssertFalse(
            PendingAccountDeletion.isPending(userID: myID),
            "完成之後旗標該清掉，不留給下一次登入誤判"
        )
    }

    func test_resumeIfNeeded_pendingFlagSet_finalizeFails_movesToFailed_flagStaysPending() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler { throw AppError.server(message: "ef down", code: nil) }
        let fixture = makeResumableFixture(accountAPIClient: stub)

        fixture.model.resumeIfNeeded()
        let met = await waitUntil {
            if case .failed = fixture.model.step { return true }
            return false
        }
        XCTAssertTrue(met, "等待轉入 04h 逾時（1 秒）")

        XCTAssertTrue(
            PendingAccountDeletion.isPending(userID: myID),
            "EF 還沒成功，旗標必須留著，下次啟動才能再續傳"
        )
    }

    /// **merge-review R2 B2**：續傳失敗後 04h「重試」（`confirmDeletion()`）必須走
    /// `resumer.retry(userID:)`，不是 `performDeletion()`——這個 model 實例的 `deletionRequested`
    /// 對續傳情境毫無意義（一律是 `false`），若誤走 `performDeletion()` 會重打已經成功過的
    /// `deleteMyAccount()` RPC。
    func test_confirmDeletion_afterResumeFails_retriesViaResumer_notPerformDeletion() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        let finalizeShouldFail = OSAllocatedUnfairLock(initialState: true)
        stub.setFinalizeHandler {
            if finalizeShouldFail.withLock({ $0 }) {
                throw AppError.server(message: "ef down", code: nil)
            }
        }
        let fixture = makeResumableFixture(accountAPIClient: stub)

        fixture.model.resumeIfNeeded()
        let firstAttemptFailed = await waitUntil {
            if case .failed = fixture.model.step { return true }
            return false
        }
        XCTAssertTrue(firstAttemptFailed, "等待第一次續傳失敗逾時（1 秒）")

        finalizeShouldFail.withLock { $0 = false }
        fixture.model.confirmDeletion()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待重試完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 0, "續傳情境下 RPC 早就成功過，重試不該呼叫它")
        XCTAssertEqual(stub.finalizeCallCount, 2)
    }

    /// `performDeletion()` 這一側：一般（非續傳）路徑 RPC 成功的當下就該落地旗標——不是等到
    /// EF 也成功才記，因為 EF 那一步失敗／app 被殺掉正是這支旗標要保護的情境。
    func test_confirmDeletion_rpcSucceeds_marksPendingFlagBeforeFinalizeResolves() async {
        let session = AuthSession(userID: myID, email: "a@example.com", expiresAt: .distantFuture)
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFinalizeHandler {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next() // 卡住 EF，確保斷言發生在「RPC 成功、EF 還沒回」的窗口
        }
        let fixture = makeModel(
            accountAPIClient: stub, members: [makeMember(id: myID, role: .member)],
            authStub: StubAuthService(currentSession: session)
        )

        fixture.model.confirmDeletion()
        let rpcDone = await waitUntil { fixture.model.deletionRequested }
        XCTAssertTrue(rpcDone, "等待 RPC 完成逾時（1 秒）")

        XCTAssertTrue(
            PendingAccountDeletion.isPending(userID: myID),
            "RPC 成功的當下就該落地旗標，不等 EF 也成功"
        )

        gateContinuation.finish()
    }

    /// **merge-review R3 n1 核心釘樁**：手動流程（04e 送出後）的 EF 呼叫在飛時，若這個
    /// `userID` 剛好也被自動續傳路徑（`AuthenticatedGate`／`ForkView` 的
    /// `resumer.resumeIfPending`）觸發到，兩者必須共用同一個 `Task`——`finalizeAccountDeletion()`
    /// 只會被呼叫一次。這正是 `PendingAccountDeletionResumer`「唯一擁有者」這句型別文件宣稱
    /// 要成立的地方；R3 版 `performDeletion()` 仍直接呼叫 `accountAPIClient
    /// .finalizeAccountDeletion()`，沒有登記進 `resumer` 的去重，這支測試在那個版本下會失敗
    /// （見 PR body mutation 記錄）。
    func test_manualFlowFinalizeInFlight_gateTriggersAutoResume_onlyCallsFinalizeOnce() async {
        let session = AuthSession(userID: myID, email: "a@example.com", expiresAt: .distantFuture)
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setDeleteMyAccountHandler { .success }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFinalizeHandler {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next() // 卡住 EF，確保下面的「自動續傳」是在手動流程還在飛時觸發
        }
        let fixture = makeModel(
            accountAPIClient: stub, members: [makeMember(id: myID, role: .member)],
            authStub: StubAuthService(currentSession: session)
        )

        fixture.model.confirmDeletion() // 手動流程：04e 送出 → RPC 成功 → 正要打 EF（卡在 gate）
        let rpcDone = await waitUntil { fixture.model.deletionRequested }
        XCTAssertTrue(rpcDone, "等待 RPC 完成逾時（1 秒）")

        // 模擬「AuthenticatedGate 剛好在這個窗口重算 body，偵測到旗標存在，觸發自動續傳」——
        // 同一個 resumer 實例（`fixture.resumer`，跟 model 建構時共用同一份），同一個 userID。
        fixture.resumer.resumeIfPending(userID: myID)

        gateContinuation.finish()
        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待流程完成逾時（1 秒）")

        XCTAssertEqual(stub.finalizeCallCount, 1, "手動流程與自動續傳撞在一起時，EF 只該被呼叫一次")
    }
}
