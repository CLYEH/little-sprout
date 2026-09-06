import Foundation
@testable import LittleSprout
import XCTest

/// LS-193 merge-review R1 M3：`delete_my_account()` RPC 已成功、Edge Function 沒打完（app
/// 被殺掉／失敗）之後的續傳——`PendingAccountDeletion` 本機旗標存在時，`DeleteAccountFlowModel
/// .init` 必須直接跳過三分流／04e，續傳到 04f 重打 EF。跟 `DeleteAccountFlowModelTests` 是同一
/// 個測試對象，拆成獨立檔案同 `DeleteAccountFlowModelRaceTests.swift` 的既有理由——共用該檔的
/// `makeModel(...)`／`waitUntil(...)` 測試工廠方法，額外需要一個「有 session」的 `authStub`。
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

    func test_init_pendingFlagSet_immediatelyEntersInProgress_synchronously() {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let fixture = makeResumableFixture()

        // 不 await 任何東西——`step` 必須在 `init` 回傳的當下就已經是 `.inProgress`（見該屬性
        // 賦值處文件註解：不能等 `Task` 排程到才設，否則會有一格畫面閃到三分流）。
        XCTAssertEqual(fixture.model.step, .inProgress)
        XCTAssertTrue(fixture.model.deletionRequested, "旗標存在代表 RPC 上次已經成功，不該重打")
    }

    func test_init_pendingFlagSet_doesNotCallDeleteMyAccountAgain_onlyFinalize() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler {}
        let fixture = makeResumableFixture(accountAPIClient: stub)

        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待續傳完成逾時（1 秒）")

        XCTAssertEqual(stub.deleteMyAccountCallCount, 0, "RPC 上次已經成功，續傳不該重打")
        XCTAssertEqual(stub.finalizeCallCount, 1)
    }

    func test_init_pendingFlagSet_finalizeSucceeds_clearsPendingFlag() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler {}
        let fixture = makeResumableFixture(accountAPIClient: stub)

        let met = await waitUntil { fixture.model.step == .completed }
        XCTAssertTrue(met, "等待續傳完成逾時（1 秒）")

        XCTAssertFalse(
            PendingAccountDeletion.isPending(userID: myID),
            "完成之後旗標該清掉，不留給下一次登入誤判"
        )
    }

    func test_init_pendingFlagSet_finalizeFails_movesToFailed_flagStaysPending() async {
        defer { PendingAccountDeletion.clear(userID: myID) }
        let stub = StubAccountAPIClient()
        stub.setFinalizeHandler { throw AppError.server(message: "ef down", code: nil) }
        let fixture = makeResumableFixture(accountAPIClient: stub)

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
}
