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
        // request。用一個不會自己結束的 handler 卡住第一次呼叫，驗證第二次呼叫被 guard 擋下。
        let stub = StubFamilyAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let family = makeFamily()
        stub.setCreateFamilyHandler { _ in
            callCount.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(60))
            return family
        }
        let store = FamilyStore(apiClient: stub)

        let firstCallTask = Task { await store.createFamily(name: "葉家") }
        // 讓第一次呼叫先把狀態切成 .submitting，才具代表性地驗證第二次呼叫會被擋下。
        while store.createFamilyState != .submitting {
            await Task.yield()
        }

        let secondCallSucceeded = await store.createFamily(name: "葉家")

        XCTAssertFalse(secondCallSucceeded, "送出中應該擋下第二次呼叫")
        XCTAssertEqual(callCount.withLock { $0 }, 1, "底層 API 只該被呼叫一次")
        firstCallTask.cancel()
    }

    func test_resetCreateFamilyState_clearsFailureButNotSuccess() {
        let stub = StubFamilyAPIClient()
        let store = FamilyStore(apiClient: stub)

        store.resetCreateFamilyState()
        XCTAssertEqual(store.createFamilyState, .idle, "本來就是 idle，重置後仍是 idle")
    }

    // MARK: - createInvite（07 邀請家人）

    func test_createInvite_success_setsLatestInviteAndSuccessState() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setCreateInviteHandler { _, _, _, _ in "K7M2FD" }

        let code = await store.createInvite(role: .member)

        XCTAssertEqual(code, "K7M2FD")
        XCTAssertEqual(store.latestInvite?.code, "K7M2FD")
        XCTAssertEqual(store.latestInvite?.role, .member)
        XCTAssertEqual(store.latestInvite?.maxUses, FamilyStore.defaultInviteMaxUses)
        XCTAssertEqual(store.createInviteState, .success)
        // 07 沒有 UI 讓使用者自訂期限與次數——固定用既定決策（7 天／5 次）。
        XCTAssertEqual(stub.createInviteCalls.last?.maxUses, FamilyStore.defaultInviteMaxUses)
    }

    func test_createInvite_withoutFamily_failsWithoutCallingAPI() async {
        // 呼叫端自己組錯前置條件（沒有家庭卻想建邀請碼），不對應任何後端錯誤碼——不該真的打
        // 一次網路才發現這件事。
        let stub = StubFamilyAPIClient()
        stub.setCreateInviteHandler { _, _, _, _ in
            XCTFail("沒有家庭時不該呼叫 createInvite")
            throw StubFamilyAPIClient.StubError.unconfigured
        }
        let store = FamilyStore(apiClient: stub)

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code)
        guard case .failure = store.createInviteState else {
            return XCTFail("沒有家庭應該落在 .failure，實際是 \(store.createInviteState)")
        }
    }

    func test_createInvite_generationCollision_mapsToRetryableSystemTier() async {
        // LS016（邀請碼產生連續撞碼）：`AppError.LSErrorCode.tier` 定案歸 `retryableSystem`
        // （見 `AppError.swift`），跟「換個輸入」的 validationRetryable 不同層——這裡驗證
        // `FamilyStore` 原封不動把已經歸好層的錯誤存進 `createInviteState`，UI 才能依層級
        // 挑對文案（「請再試一次」而不是「檢查輸入」）。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setCreateInviteHandler { _, _, _, _ in
            throw AppError.retryableSystem(message: "請再試一次", code: "LS016")
        }

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code)
        XCTAssertEqual(store.createInviteState, .failure(.retryableSystem(message: "請再試一次", code: "LS016")))
    }

    func test_resetCreateInviteState_clearsFailureOnly() async {
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setCreateInviteHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        _ = await store.createInvite(role: .member)
        guard case .failure = store.createInviteState else {
            return XCTFail("前置條件失敗：預期先進入 .failure")
        }

        store.resetCreateInviteState()

        XCTAssertEqual(store.createInviteState, .idle)
    }
}
