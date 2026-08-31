import Foundation
@testable import LittleSprout
import os
import XCTest

/// `FamilyStore` 加入路徑（LS-108：申請人 request_join／get_my_join_request／withdraw_join；
/// owner list_join_requests／approve_join／reject_join）——查詢家庭／建立家庭／邀請碼的既有
/// 狀態機測試在 `FamilyStoreTests`／`FamilyStoreInviteTests`，拆檔理由同兩者的既有說明。
@MainActor
final class FamilyStoreJoinRequestsTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let requestID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makePendingRequest(
        requestID: UUID? = nil,
        displayName: String = "阿公",
        createdAt: Date = Date()
    ) -> PendingJoinRequest {
        PendingJoinRequest(
            requestID: requestID ?? self.requestID,
            familyID: familyID,
            applicantID: UUID(),
            displayName: displayName,
            avatarURL: nil,
            role: .member,
            createdAt: createdAt
        )
    }

    // MARK: - requestJoin（申請人）

    func test_requestJoin_pending_setsSuccessState_doesNotTouchMyFamily() async {
        let stub = StubFamilyAPIClient()
        let requestID = self.requestID
        let familyID = self.familyID
        stub.setRequestJoinHandler { _ in .pending(requestID: requestID, familyID: familyID) }
        let store = FamilyStore(apiClient: stub)

        let outcome = await store.requestJoin(code: "K7M2FD")

        XCTAssertEqual(outcome, .pending(requestID: requestID, familyID: familyID))
        XCTAssertEqual(store.requestJoinState, .success)
        XCTAssertNil(store.myFamily, "pending 不該直接放行——核准前使用者看不到任何家庭內容")
    }

    func test_requestJoin_joined_refreshesMyFamily() async {
        // 家庭關閉審核（require_approval=false）：`request_join` 直接回 joined，`FamilyStore`
        // 要自己重新查一次 `myFamily`，root routing 才會自動離開三岔路（同 `createFamily`
        // 成功後的既有慣例）。
        let stub = StubFamilyAPIClient()
        let familyID = self.familyID
        stub.setRequestJoinHandler { _ in .joined(familyID: familyID) }
        let family = Family(id: familyID, name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: false)
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)

        let outcome = await store.requestJoin(code: "K7M2FD")

        XCTAssertEqual(outcome, .joined(familyID: familyID))
        XCTAssertEqual(store.myFamily, family)
    }

    func test_requestJoin_invalidCode_setsFailureState() async {
        let stub = StubFamilyAPIClient()
        let error = AppError.validationRetryable(message: "邀請碼不存在", code: LSErrorCode.inviteCodeNotFound.rawValue)
        stub.setRequestJoinHandler { _ in throw error }
        let store = FamilyStore(apiClient: stub)

        let outcome = await store.requestJoin(code: "WRONGCODE")

        XCTAssertNil(outcome)
        XCTAssertEqual(store.requestJoinState, .failure(error))
    }

    func test_requestJoin_whileSubmitting_ignoresDuplicateCall() async {
        let stub = StubFamilyAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let requestID = self.requestID
        let familyID = self.familyID
        stub.setRequestJoinHandler { _ in
            callCount.withLock { $0 += 1 }
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return .pending(requestID: requestID, familyID: familyID)
        }
        let store = FamilyStore(apiClient: stub)

        let firstCallTask = Task { await store.requestJoin(code: "K7M2FD") }
        var guardIterations = 0
        while store.requestJoinState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 requestJoinState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let secondOutcome = await store.requestJoin(code: "K7M2FD")

        XCTAssertNil(secondOutcome, "送出中應該直接擋下第二次呼叫")
        XCTAssertEqual(callCount.withLock { $0 }, 1, "底層 API 只該被呼叫一次")

        gateContinuation.finish()
        _ = await firstCallTask.value
    }

    func test_resetRequestJoinState_clearsFailureOnly() async {
        let stub = StubFamilyAPIClient()
        stub.setRequestJoinHandler { _ in throw AppError.network(message: "offline") }
        let store = FamilyStore(apiClient: stub)
        _ = await store.requestJoin(code: "K7M2FD")
        guard case .failure = store.requestJoinState else {
            return XCTFail("前置條件失敗：預期先進入 .failure")
        }

        store.resetRequestJoinState()

        XCTAssertEqual(store.requestJoinState, .idle)
    }

    // MARK: - refreshMyJoinRequest（06d 輪詢）

    func test_refreshMyJoinRequest_success_setsMyJoinRequest() async {
        let stub = StubFamilyAPIClient()
        let request = MyJoinRequest(
            requestID: requestID, familyID: familyID, familyName: "陳家",
            status: .pending, createdAt: Date(), resolvedAt: nil
        )
        stub.setMyJoinRequestHandler { request }
        let store = FamilyStore(apiClient: stub)

        let result = await store.refreshMyJoinRequest()

        XCTAssertEqual(result, request)
        XCTAssertEqual(store.myJoinRequest, request)
    }

    func test_refreshMyJoinRequest_failure_keepsLastKnownValue() async {
        // 輪詢失敗（多半是網路）刻意不覆寫——見 `FamilyStore.refreshMyJoinRequest` 文件註解。
        let stub = StubFamilyAPIClient()
        let request = MyJoinRequest(
            requestID: requestID, familyID: familyID, familyName: "陳家",
            status: .pending, createdAt: Date(), resolvedAt: nil
        )
        let shouldFail = OSAllocatedUnfairLock(initialState: false)
        stub.setMyJoinRequestHandler {
            if shouldFail.withLock({ $0 }) { throw AppError.network(message: "offline") }
            return request
        }
        let store = FamilyStore(apiClient: stub)
        _ = await store.refreshMyJoinRequest()
        XCTAssertEqual(store.myJoinRequest, request, "前置條件失敗：預期先查到這筆申請")

        shouldFail.withLock { $0 = true }
        let result = await store.refreshMyJoinRequest()

        XCTAssertEqual(result, request, "輪詢失敗要保留最後已知狀態，不能把畫面閃成空白")
        XCTAssertEqual(store.myJoinRequest, request)
    }

    // MARK: - withdrawJoinRequest

    func test_withdrawJoinRequest_success_setsSuccessState() async {
        let stub = StubFamilyAPIClient()
        stub.setWithdrawJoinHandler { _ in }
        let store = FamilyStore(apiClient: stub)

        let succeeded = await store.withdrawJoinRequest(requestID: requestID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.withdrawJoinState, .success)
        XCTAssertEqual(stub.withdrawJoinCalls, [requestID])
    }

    func test_withdrawJoinRequest_alreadyProcessed_setsFailureState() async {
        let stub = StubFamilyAPIClient()
        let error = AppError.rejected(message: "申請已被處理", code: LSErrorCode.requestNotFoundOrProcessed.rawValue)
        stub.setWithdrawJoinHandler { _ in throw error }
        let store = FamilyStore(apiClient: stub)

        let succeeded = await store.withdrawJoinRequest(requestID: requestID)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.withdrawJoinState, .failure(error))
    }

    // MARK: - refreshPendingJoinRequests（owner 審核清單）

    func test_refreshPendingJoinRequests_success_populatesList() async {
        let stub = StubFamilyAPIClient()
        let request = makePendingRequest()
        stub.setListJoinRequestsHandler { [request] }
        let store = FamilyStore(apiClient: stub)

        let result = await store.refreshPendingJoinRequests()

        XCTAssertEqual(result, [request])
        XCTAssertEqual(store.pendingJoinRequests, [request])
        XCTAssertEqual(store.listJoinRequestsState, .success)
    }

    // MARK: - approveJoinRequest／rejectJoinRequest（owner 動作）

    func test_approveJoinRequest_success_removesFromLocalList() async {
        let stub = StubFamilyAPIClient()
        let request = makePendingRequest()
        stub.setListJoinRequestsHandler { [request] }
        stub.setApproveJoinHandler { _ in }
        let store = FamilyStore(apiClient: stub)
        _ = await store.refreshPendingJoinRequests()

        let succeeded = await store.approveJoinRequest(request.requestID)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(store.pendingJoinRequests.isEmpty, "核准成功要把這筆從本地清單移除，不必整份重查")
        XCTAssertEqual(stub.approveJoinCalls, [request.requestID])
    }

    func test_rejectJoinRequest_raceAlreadyProcessed_setsActionErrorAndKeepsRow() async {
        // 兩台裝置同時處理同一筆申請：docs/API.md §4 `approve_join`／`reject_join` 併發段落
        // ——後到的那邊拿到 `LS015`。這裡驗證 store 把錯誤存進 `joinRequestActionError`，且
        // 不把這筆從清單裡誤刪（既然沒有真的處理成功）。
        let stub = StubFamilyAPIClient()
        let request = makePendingRequest()
        stub.setListJoinRequestsHandler { [request] }
        let error = AppError.rejected(message: "申請已被處理", code: LSErrorCode.requestNotFoundOrProcessed.rawValue)
        stub.setRejectJoinHandler { _ in throw error }
        let store = FamilyStore(apiClient: stub)
        _ = await store.refreshPendingJoinRequests()

        let succeeded = await store.rejectJoinRequest(request.requestID)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.joinRequestActionError, error)
        XCTAssertEqual(store.pendingJoinRequests, [request])
    }

    func test_isProcessingJoinRequest_trueWhileActionInFlight_perRequestID() async {
        // 核准 A 不擋拒絕 B——每筆申請各自的旗標，見 `FamilyStore.isProcessingJoinRequest` 文件。
        let stub = StubFamilyAPIClient()
        let requestA = makePendingRequest(requestID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let requestB = makePendingRequest(requestID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
        stub.setListJoinRequestsHandler { [requestA, requestB] }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setApproveJoinHandler { _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        stub.setRejectJoinHandler { _ in }
        let store = FamilyStore(apiClient: stub)
        _ = await store.refreshPendingJoinRequests()

        let approveTask = Task { await store.approveJoinRequest(requestA.requestID) }
        var guardIterations = 0
        while !store.isProcessingJoinRequest(requestA.requestID) {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 A 進入處理中逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(store.isProcessingJoinRequest(requestB.requestID), "B 不該被 A 卡住")
        let rejectSucceeded = await store.rejectJoinRequest(requestB.requestID)
        XCTAssertTrue(rejectSucceeded)

        gateContinuation.finish()
        _ = await approveTask.value
        XCTAssertFalse(store.isProcessingJoinRequest(requestA.requestID), "完成後旗標要清掉")
    }

    // MARK: - resetJoinRequestsState（換使用者／登出，經由 FamilyStore.reset()）

    func test_reset_clearsAllJoinRequestsState() async {
        let stub = StubFamilyAPIClient()
        stub.setRequestJoinHandler { _ in throw AppError.network(message: "offline") }
        let request = makePendingRequest()
        stub.setListJoinRequestsHandler { [request] }
        let store = FamilyStore(apiClient: stub)
        _ = await store.requestJoin(code: "K7M2FD")
        _ = await store.refreshPendingJoinRequests()
        XCTAssertFalse(store.pendingJoinRequests.isEmpty, "前置條件失敗")

        store.reset()

        XCTAssertEqual(store.requestJoinState, .idle)
        XCTAssertNil(store.myJoinRequest)
        XCTAssertEqual(store.withdrawJoinState, .idle)
        XCTAssertEqual(store.listJoinRequestsState, .idle)
        XCTAssertTrue(store.pendingJoinRequests.isEmpty)
        XCTAssertNil(store.joinRequestActionError)
    }
}
