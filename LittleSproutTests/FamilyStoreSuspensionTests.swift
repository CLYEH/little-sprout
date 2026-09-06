import Foundation
@testable import LittleSprout
import XCTest

/// LS-193 merge-review R1 M2：`FamilyStore.suspendedOrRegistrationClosedError`——`ForkView`
/// 「登出」／「刪除帳號」文字鈕列的顯示條件，即時讀最近一次 `createFamilyState`／
/// `requestJoinState` 的錯誤碼（見該屬性文件註解）。獨立成新檔案（不是加進
/// `FamilyStoreTests.swift`）：範圍窄、避免那支既有檔案疊上不相關的新 MARK 段。
@MainActor
final class FamilyStoreSuspensionTests: XCTestCase {
    private func makeStore() -> FamilyStore {
        FamilyStore(apiClient: StubFamilyAPIClient(), avatarUploadService: StubChildAvatarUploadService())
    }

    func test_suspendedOrRegistrationClosedError_noFailures_nil() {
        let store = makeStore()
        XCTAssertNil(store.suspendedOrRegistrationClosedError)
    }

    func test_suspendedOrRegistrationClosedError_createFamilyFailsWithLS052_returnsError() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "帳號已停權", code: "LS052") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertEqual(store.suspendedOrRegistrationClosedError, .rejected(message: "帳號已停權", code: "LS052"))
    }

    func test_suspendedOrRegistrationClosedError_createFamilyFailsWithLS054_returnsError() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "暫停開放新註冊", code: "LS054") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertEqual(store.suspendedOrRegistrationClosedError, .rejected(message: "暫停開放新註冊", code: "LS054"))
    }

    func test_suspendedOrRegistrationClosedError_requestJoinFailsWithLS052_returnsError() async {
        let stub = StubFamilyAPIClient()
        stub.setRequestJoinHandler { _ in throw AppError.rejected(message: "帳號已停權", code: "LS052") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.requestJoin(code: "ABC123")

        XCTAssertEqual(store.suspendedOrRegistrationClosedError, .rejected(message: "帳號已停權", code: "LS052"))
    }

    /// 不是所有失敗都該顯示「登出／刪除帳號」出口——一般網路錯誤（可重試）不該被誤判成停權。
    func test_suspendedOrRegistrationClosedError_unrelatedFailure_nil() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.network(message: "offline") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertNil(store.suspendedOrRegistrationClosedError)
    }

    /// 不相干的自訂錯誤碼（例如 `LS054` 以外的 `rejected`）也不該誤判。
    func test_suspendedOrRegistrationClosedError_differentRejectedCode_nil() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "其他拒絕", code: "LS999") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertNil(store.suspendedOrRegistrationClosedError)
    }

    // MARK: - accountDeletionInProgressError（merge-review R1 M3：LS051）

    func test_accountDeletionInProgressError_noFailures_nil() {
        let store = makeStore()
        XCTAssertNil(store.accountDeletionInProgressError)
    }

    func test_accountDeletionInProgressError_createFamilyFailsWithLS051_returnsError() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "帳號已請求刪除", code: "LS051") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertEqual(store.accountDeletionInProgressError, .rejected(message: "帳號已請求刪除", code: "LS051"))
        XCTAssertNil(store.suspendedOrRegistrationClosedError, "LS051 不是 LS052／LS054，兩個屬性互斥")
    }

    func test_accountDeletionInProgressError_requestJoinFailsWithLS051_returnsError() async {
        let stub = StubFamilyAPIClient()
        stub.setRequestJoinHandler { _ in throw AppError.rejected(message: "帳號已請求刪除", code: "LS051") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.requestJoin(code: "ABC123")

        XCTAssertEqual(store.accountDeletionInProgressError, .rejected(message: "帳號已請求刪除", code: "LS051"))
    }

    /// LS052 不該被 `accountDeletionInProgressError` 誤判——兩個屬性各自只認自己的錯誤碼。
    func test_accountDeletionInProgressError_ls052Failure_nil() async {
        let stub = StubFamilyAPIClient()
        stub.setCreateFamilyHandler { _ in throw AppError.rejected(message: "帳號已停權", code: "LS052") }
        let store = FamilyStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.createFamily(name: "陳家")

        XCTAssertNil(store.accountDeletionInProgressError)
        XCTAssertNotNil(store.suspendedOrRegistrationClosedError, "前置：LS052 應該被另一個屬性抓到")
    }
}
