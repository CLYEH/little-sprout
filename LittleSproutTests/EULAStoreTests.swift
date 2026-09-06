@testable import LittleSprout
import XCTest

// `AsyncGate`（讓 stub handler 可以卡在「還在 in-flight」直到測試主動放行，測
// `guard !isSubmitting` 與換帳號時序需要能精準控制 await 的時間點）LS-214 起搬到
// `LittleSproutTests/Support/AsyncGate.swift` 與 `TimelineStoreTests.swift` 共用，見該檔。

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

    // MARK: - B2(b)（merge-review R1）：`isKnown(for:)` 換帳號／`.submitting` 一律視為未知

    func test_isKnown_falseForDifferentUserID() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        XCTAssertTrue(store.isKnown(for: userID))
        XCTAssertFalse(store.isKnown(for: UUID()), "換一個不同的 userID 不該信任目前的 shouldPresent")
    }

    /// 對應 merge-review R1 B2 失敗情境：A 同意（`shouldPresent == false`）→ 同機換 B 登入
    /// →（網路還沒回來）`AuthenticatedGate` 不能沿用 A 殘留的 `shouldPresent == false` 誤放行。
    func test_checkStatus_newUser_resetsStaleShouldPresentBeforeNetworkReturns() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in "2026-09-05-draft" }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID) // A 同意過 → shouldPresent == false
        XCTAssertEqual(store.shouldPresent, false)

        let otherUserID = UUID()
        let gate = AsyncGate()
        stub.setFetchCurrentVersionHandler {
            await gate.wait()
            return "2026-09-05-draft"
        }
        let task = Task { await store.checkStatus(userID: otherUserID) }
        while !store.checkState.isSubmitting {
            await Task.yield()
        }

        XCTAssertNil(store.shouldPresent, "換帳號應立即清掉舊使用者殘留的 shouldPresent，不等網路回來")
        XCTAssertFalse(store.isKnown(for: otherUserID), "網路還沒回來，B 的結果不可信任")

        await gate.open()
        await task.value
        XCTAssertTrue(store.isKnown(for: otherUserID))
    }

    // MARK: - m1（merge-review R1）：`guard !isSubmitting` 擋重複呼叫

    /// `async let` 起的子任務何時真的開始執行（呼叫進 `fetchCurrentVersion` 本體）不保證跟父
    /// 任務同一輪 runloop——用迴圈等到 `checkState` 真的翻成 `.submitting`（那一行在
    /// `async let` 之前同步執行，比子任務排程更早），而不是猜一次 `Task.yield()` 夠不夠，
    /// 避免測試本身時序不穩。呼叫次數改在兩個任務都確定完成之後才驗，不在競態視窗中間看。
    ///
    /// merge-review R2 m5：第二次呼叫包在自己的 `Task`（`task2`）裡，不直接 `await`——
    /// `guard` 被 mutation 拿掉時，第二次呼叫也會需要 `gate.open()` 才能完成；若直接
    /// `await store.checkStatus(...)` inline，測試自己的執行流程會卡住（要先跑完這行才能往下
    /// 跑到 `gate.open()` 那行，但這行本身要等 `gate.open()` 才能跑完——結構性互相依賴，
    /// 不是 `AsyncGate` 是否支援多個等待者的問題）。包成 `Task` 之後，`gate.open()` 這行
    /// 不需要等第二次呼叫先完成就能執行，兩支 task 才都會真的結束。
    func test_checkStatus_whileSubmitting_secondCallDoesNotRefetch() async {
        let stub = StubEULAAPIClient()
        let gate = AsyncGate()
        stub.setFetchCurrentVersionHandler {
            await gate.wait()
            return "2026-09-05-draft"
        }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)

        let task1 = Task { await store.checkStatus(userID: userID) }
        while !store.checkState.isSubmitting {
            await Task.yield()
        }

        // 第二次呼叫應該被 guard 立刻擋掉、不再送一次網路請求（也不會卡在 gate 上）。
        let task2 = Task { await store.checkStatus(userID: userID) }

        await gate.open()
        await task1.value
        await task2.value

        XCTAssertEqual(stub.fetchCurrentVersionCallCount, 1, "guard !checkState.isSubmitting 應該擋掉同一輪內的重複呼叫")
    }

    /// 「刪除後狀態」對應本票驗收條件（同意成功後）：`shouldPresent` 收回 `false`，不需要
    /// 重新 `checkStatus` 才能放行。
    func test_accept_success_setsShouldPresentFalse() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        let succeeded = await store.accept()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.shouldPresent, false)
        XCTAssertEqual(store.acceptState, .idle)
        XCTAssertEqual(stub.acceptEULACalls, ["2026-09-05-draft"])
    }

    /// `StubEULAAPIClient` 不是 `@MainActor`——`try await apiClient.acceptEULA(...)` 從
    /// `@MainActor` 的 `accept()` 呼叫過去要跨 actor，即使 callee 裡緊接著就是同步的
    /// `acceptEULACalls.append(...)`，跨 actor 本身就是一個 suspension point：`acceptState`
    /// 已經翻成 `.submitting`（MainActor 這側）不代表 `append` 已經在另一側跑完。同
    /// `test_checkStatus_whileSubmitting_secondCallDoesNotRefetch` 的理由，呼叫次數改在
    /// gate 打開、`task1` 確定完成之後才驗，不在競態視窗中間看。
    ///
    /// merge-review R2 m5：第二次呼叫同上改包在 `task2` 裡、不直接 `await`——理由同
    /// `test_checkStatus_whileSubmitting_secondCallDoesNotRefetch` 文件註解（guard 被拿掉時
    /// 直接 inline await 會讓測試自己的執行流程卡死）。回傳值（是否被 guard 擋掉）改成
    /// `await task2.value` 之後才驗，語意不變。
    func test_accept_whileSubmitting_secondCallDoesNotResend() async {
        let stub = StubEULAAPIClient()
        stub.setFetchCurrentVersionHandler { "2026-09-05-draft" }
        stub.setFetchAcceptedVersionHandler { _ in nil }
        let store = EULAStore(apiClient: stub)
        await store.checkStatus(userID: userID)

        let gate = AsyncGate()
        stub.setAcceptEULAHandler { _ in await gate.wait() }
        let task1 = Task { await store.accept() }
        while !store.acceptState.isSubmitting {
            await Task.yield()
        }

        let task2 = Task { await store.accept() }

        await gate.open()
        await task1.value
        let secondResult = await task2.value

        XCTAssertFalse(secondResult, "guard !acceptState.isSubmitting 應該擋掉同一輪內的重複呼叫")
        XCTAssertEqual(stub.acceptEULACalls.count, 1)
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

        let succeeded = await store.accept()

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

        let succeeded = await store.accept()

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
        XCTAssertFalse(store.isKnown(for: userID), "reset() 後 judgedUserID 也要清掉，否則換帳號後這個 userID 又被誤判成已知")
    }
}
