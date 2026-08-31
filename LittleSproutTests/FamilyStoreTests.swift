import Foundation
@testable import LittleSprout
import os
import XCTest

/// `FamilyStore` 狀態機（idle／submitting／success／failure(AppError)）：LS-107 三岔路／
/// 建立家庭／邀請家人三個畫面都依這裡的狀態直接重繪，見該檔文件註解。
@MainActor
final class FamilyStoreTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeFamily(id: UUID? = nil, name: String = "陳家") -> Family {
        Family(id: id ?? familyID, name: name, createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    // MARK: - refreshMyFamily（三岔路 root routing 依這個結果判斷）

    func test_refreshMyFamily_hasFamily_setsMyFamilyAndSuccess() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)

        let result = await store.refreshMyFamily()

        XCTAssertEqual(result, family)
        XCTAssertEqual(store.myFamily, family)
        XCTAssertEqual(store.lookupState, .success)
    }

    func test_refreshMyFamily_noFamily_setsNilAndSuccess() async {
        // 全新帳號、還沒建立或加入任何家庭：nil 是合法結果，不是錯誤（§9-C5 三岔路情境）。
        let stub = StubFamilyAPIClient()
        stub.setFetchMyFamilyHandler { nil }
        let store = FamilyStore(apiClient: stub)

        let result = await store.refreshMyFamily()

        XCTAssertNil(result)
        XCTAssertNil(store.myFamily)
        XCTAssertEqual(store.lookupState, .success)
    }

    func test_refreshMyFamily_networkFailure_setsFailureStateWithoutTouchingMyFamily() async {
        let stub = StubFamilyAPIClient()
        stub.setFetchMyFamilyHandler { throw AppError.network(message: "offline") }
        let store = FamilyStore(apiClient: stub)

        let result = await store.refreshMyFamily()

        XCTAssertNil(result)
        XCTAssertEqual(store.lookupState, .failure(.network(message: "offline")))
    }

    func test_refreshMyFamily_whileSubmitting_ignoresDuplicateCallAndOnlyCallsAPIOnce() async {
        // R1 F8：跟 createFamily／createInvite 對稱的 in-flight guard——`syncOwner` 落地後
        // `refreshMyFamily` 多了第二個觸發點，兩個併發呼叫的完成順序原本會決定最終
        // `myFamily`，這裡驗證第二次呼叫直接被擋下，不重新發一次請求。
        let stub = StubFamilyAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler {
            callCount.withLock { $0 += 1 }
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return family
        }
        let store = FamilyStore(apiClient: stub)

        let firstCallTask = Task { await store.refreshMyFamily() }
        var guardIterations = 0
        while store.lookupState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 lookupState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let secondResult = await store.refreshMyFamily()

        XCTAssertEqual(secondResult, nil, "送出中應該直接回傳目前值（尚未有結果，是 nil）")
        XCTAssertEqual(callCount.withLock { $0 }, 1, "底層 API 只該被呼叫一次")

        gateContinuation.finish()
        _ = await firstCallTask.value
    }

    // MARK: - createFamily（05 建立家庭）

    func test_createFamily_success_setsMyFamilyAndSuccessState() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily(name: "葉家")
        stub.setCreateFamilyHandler { name in
            XCTAssertEqual(name, "葉家")
            return family
        }
        let store = FamilyStore(apiClient: stub)

        let succeeded = await store.createFamily(name: "葉家")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.myFamily, family)
        XCTAssertEqual(store.createFamilyState, .success)
    }

    // MARK: - showsChildOnboarding（LS-113：建立家庭後可接、可跳過的寶貝建檔步驟）

    func test_createFamily_success_setsShowsChildOnboarding() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily(name: "葉家")
        stub.setCreateFamilyHandler { _ in family }
        let store = FamilyStore(apiClient: stub)

        _ = await store.createFamily(name: "葉家")

        XCTAssertTrue(store.showsChildOnboarding)
    }

    func test_createFamily_failure_doesNotSetShowsChildOnboarding() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "沒有權限", code: "42501") }
        let store = FamilyStore(apiClient: stub)

        _ = await store.createFamily(name: "葉家")

        XCTAssertFalse(store.showsChildOnboarding)
    }

    func test_dismissChildOnboarding_clearsFlag() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily(name: "葉家")
        stub.setCreateFamilyHandler { _ in family }
        let store = FamilyStore(apiClient: stub)
        _ = await store.createFamily(name: "葉家")
        XCTAssertTrue(store.showsChildOnboarding)

        store.dismissChildOnboarding()

        XCTAssertFalse(store.showsChildOnboarding)
    }

    func test_reset_clearsShowsChildOnboarding() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily(name: "葉家")
        stub.setCreateFamilyHandler { _ in family }
        let store = FamilyStore(apiClient: stub)
        _ = await store.createFamily(name: "葉家")
        XCTAssertTrue(store.showsChildOnboarding)

        store.reset()

        XCTAssertFalse(store.showsChildOnboarding)
    }

    func test_createFamily_rlsRejection_setsFailureStateWithRejectedTier() async {
        // 42501（未登入／權限不足）對映 `AppError.rejected`——store 必須原封不動把
        // `SupabaseFamilyAPIClient` 已經歸好層的錯誤存進 `createFamilyState`，不能自己再猜。
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "沒有權限", code: "42501") }
        let store = FamilyStore(apiClient: stub)

        let succeeded = await store.createFamily(name: "葉家")

        XCTAssertFalse(succeeded)
        XCTAssertNil(store.myFamily)
        XCTAssertEqual(store.createFamilyState, .failure(.rejected(message: "沒有權限", code: "42501")))
    }

    func test_createFamily_whileSubmitting_ignoresDuplicateCall() async {
        // in-flight disable（不是驗證型 disable）：使用者連點兩下「建立家庭」不該送出兩個
        // request。用一個由測試自己控制何時放行的 handler 卡住第一次呼叫（不用真的
        // `Task.sleep` 卡固定秒數——那會讓這條測試在整個測試套件一起跑時變成一個真的要等待
        // 的背景 Task，拖慢或拖亂其他測試，Rule 5：不用計時器測並行，用確定性訊號），驗證
        // 第二次呼叫被 guard 擋下。
        let stub = StubFamilyAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let family = makeFamily()
        stub.setCreateFamilyHandler { _ in
            callCount.withLock { $0 += 1 }
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next() // 卡住，直到測試呼叫 gateContinuation.finish() 才放行
            return family
        }
        let store = FamilyStore(apiClient: stub)

        let firstCallTask = Task { await store.createFamily(name: "葉家") }
        // 讓第一次呼叫先把狀態切成 .submitting，才具代表性地驗證第二次呼叫會被擋下。
        // `Task.yield()` 只保證「讓出這一次」，不保證 MainActor 排程器接下來一定先跑
        // firstCallTask（整個測試套件併發跑、佇列上還有其他工作時不可靠，實測會偶發失敗）；
        // 改用 `AuthStoreTests` 已驗證過會動的短輪詢寫法（`try await Task.sleep(nanoseconds:)`）。
        // R1 F7：輪詢加上限＋`XCTFail`——原本 `while ... { try? await Task.sleep(...) }`
        // 若 store 從此不進 `.submitting`，不是測試失敗而是掛到 XCTest timeout（診斷訊息
        // 沒用）；若這個 Task 被取消，`Task.sleep` 立即 throw、`try?` 吞掉會變成熱迴圈空轉。
        var guardIterations = 0
        while store.createFamilyState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 createFamilyState 進入 .submitting 逾時（1 秒）")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let secondCallSucceeded = await store.createFamily(name: "葉家")

        XCTAssertFalse(secondCallSucceeded, "送出中應該擋下第二次呼叫")
        XCTAssertEqual(callCount.withLock { $0 }, 1, "底層 API 只該被呼叫一次")

        gateContinuation.finish()
        let firstCallSucceeded = await firstCallTask.value
        XCTAssertTrue(firstCallSucceeded, "放行後第一次呼叫應該正常完成")
    }

    // R1 F6：原本的 `test_resetCreateFamilyState_clearsFailureButNotSuccess` 只斷言
    // idle → idle，既沒測「清掉 failure」也沒測「保留 success」——把 `resetCreateFamilyState`
    // 的 `guard case .failure` 拿掉、或反過來寫成清掉 success，那條測試照樣綠。拆成兩條，
    // 對照 `test_resetCreateInviteState_clearsFailureOnly` 的樣子。

    func test_resetCreateFamilyState_clearsFailure() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.network(message: "offline") }
        let store = FamilyStore(apiClient: stub)
        _ = await store.createFamily(name: "葉家")
        guard case .failure = store.createFamilyState else {
            return XCTFail("前置條件失敗：預期先進入 .failure")
        }

        store.resetCreateFamilyState()

        XCTAssertEqual(store.createFamilyState, .idle)
    }

    func test_resetCreateFamilyState_doesNotClearSuccess() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily(name: "葉家")
        stub.setCreateFamilyHandler { _ in family }
        let store = FamilyStore(apiClient: stub)
        _ = await store.createFamily(name: "葉家")
        XCTAssertEqual(store.createFamilyState, .success, "前置條件失敗：預期先進入 .success")

        store.resetCreateFamilyState()

        XCTAssertEqual(store.createFamilyState, .success, "guard case .failure 只該清 failure，success 不該被動到")
    }

}
