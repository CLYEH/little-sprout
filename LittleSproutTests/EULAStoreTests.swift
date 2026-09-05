@testable import LittleSprout
import XCTest

@MainActor
final class EULAStoreTests: XCTestCase {
    private let userID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func test_checkStatus_noAcceptedRecord_shouldPresentTrue() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)

        await store.checkStatus(userID: userID)

        XCTAssertEqual(store.checkState, .idle)
        XCTAssertEqual(store.shouldPresent, true)
        XCTAssertEqual(store.currentVersion, "2026-09-05-draft")
    }

    func test_checkStatus_acceptedCurrentVersion_shouldPresentFalse() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in "2026-09-05-draft" }
        let store = EULAStore(apiClient: stub)

        await store.checkStatus(userID: userID)

        XCTAssertEqual(store.shouldPresent, false)
    }

    func test_checkStatus_failure_setsFailureState() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { throw AppError.network(message: "offline") }
        let store = EULAStore(apiClient: stub)

        await store.checkStatus(userID: userID)

        guard case .failure = store.checkState else {
            return XCTFail("預期 checkState 為 .failure，實際是 \(store.checkState)")
        }
        XCTAssertNil(store.shouldPresent)
    }

    /// 「刪除後狀態」對應本票驗收條件（同意成功後）：`shouldPresent` 收回 `false`，不需要
    /// 重新 `checkStatus` 才能放行。
    func test_accept_success_setsShouldPresentFalse() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        let succeeded = await store.accept(userID: userID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.shouldPresent, false)
        XCTAssertEqual(store.acceptState, .idle)
        XCTAssertEqual(stub.acceptEULACalls, ["2026-09-05-draft"])
    }

    /// LS055（版本不符）：自動重抓一次目前版本，供使用者下次按「同意並繼續」時重試。
    func test_accept_versionMismatch_refreshesCurrentVersionAndStaysPresented() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        stub.setFetchCurrentVersionHandler { "2026-10-01-draft" }
        stub.setAcceptEULAHandler { _ in
            throw AppError.rejected(message: "條款版本已更新，請重新閱讀", code: LSErrorCode.eulaVersionMismatch.rawValue)
        }

        let succeeded = await store.accept(userID: userID)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.currentVersion, "2026-10-01-draft", "LS055 應自動重抓一次目前版本")
        XCTAssertNotEqual(store.shouldPresent, false, "版本不符時不應誤放行")
        guard case .failure = store.acceptState else {
            return XCTFail("預期 acceptState 為 .failure，實際是 \(store.acceptState)")
        }
    }

    func test_accept_otherError_doesNotRefetchVersion() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        stub.setAcceptEULAHandler { _ in
            throw AppError.rejected(message: "帳號資料異常，請聯絡我們", code: LSErrorCode.accountProfileMissing.rawValue)
        }

        let succeeded = await store.accept(userID: userID)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.currentVersion, "2026-09-05-draft", "LS056 不是版本不符，不應該重抓版本")
    }

    func test_reset_clearsAllState() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        store.reset()

        XCTAssertEqual(store.checkState, .idle)
        XCTAssertEqual(store.acceptState, .idle)
        XCTAssertNil(store.currentVersion)
        XCTAssertNil(store.shouldPresent)
    }
}
