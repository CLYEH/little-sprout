import Foundation
@testable import LittleSprout
import os
import XCTest

/// R2 merge-review（comment `9dfd1a9c`）N1：`refreshLatestInvite()` 與 `createInvite()` 共寫
/// `latestInvite`／`createInviteState` 毫無協調——查詢進行中／失敗時使用者仍能按「產生邀請碼」，
/// 把 R1 F2/F4 剛消滅的「多支碼同時有效」「app 說作廢其實還活著」放回來。這裡的四條測試對應
/// finding 列出的三個具體情境；跟其餘邀請碼生命週期測試分開只是 SwiftLint `type_body_length`
/// （250 行）撞到才拆檔（同 `FamilyStoreInviteTests` 檔頭的拆檔理由），兩者共用同一份
/// `StubFamilyAPIClient`。
@MainActor
final class FamilyStoreInviteRaceTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeFamily(id: UUID? = nil, name: String = "陳家") -> Family {
        Family(id: id ?? familyID, name: name, createdBy: UUID(), createdAt: Date(), requireApproval: true)
    }

    private func makeInviteRecord(
        id: UUID = UUID(),
        code: String = "K7M2FD",
        role: FamilyRole = .member,
        maxUses: Int = FamilyStore.defaultInviteMaxUses,
        usedCount: Int = 0,
        expiresAt: Date = Date().addingTimeInterval(7 * 86400)
    ) -> InviteRecord {
        InviteRecord(id: id, code: code, role: role, maxUses: maxUses, usedCount: usedCount, expiresAt: expiresAt)
    }

    func test_scenarioB_lookupFailsThenGenerate_createInviteStillWorksIndependentlyOfLookupFailure() async {
        // 情境 B（純序列，不需要任何交錯）：進場查詢失敗。舊寫法會把這個失敗寫進
        // `createInviteState`，讓使用者誤以為「產生」失敗；也讓 `createInvite` 開頭「送出中
        // 不可再送」的 guard 檢查一個被查詢污染過的狀態格。這裡驗證查詢失敗只影響
        // `lookupInviteState`，`createInviteState` 維持 idle 不受影響，且接下來使用者正常
        // 按「產生邀請碼」時行為完全正常（兩個狀態真正獨立）。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()
        stub.setFetchLatestActiveInviteHandler { _ in throw AppError.network(message: "offline") }

        let lookupResult = await store.refreshLatestInvite()

        XCTAssertNil(lookupResult)
        XCTAssertEqual(store.lookupInviteState, .failure(.network(message: "offline")))
        XCTAssertEqual(
            store.createInviteState, .idle,
            "查詢失敗不該動到 createInviteState——這正是 R2 N1 情境 C（guard 形同失效）的根因"
        )

        let record = makeInviteRecord(code: "NEW001")
        stub.setCreateInviteHandler { _, _, _, _ in record }
        let code = await store.createInvite(role: .member)

        XCTAssertEqual(code, "NEW001", "查詢失敗不該影響之後正常的產生流程")
        XCTAssertEqual(store.createInviteState, .success)
        XCTAssertEqual(store.latestInvite?.code, "NEW001")
    }

    func test_createInvite_whileLookupInFlight_isBlockedAndDoesNotCreateOrphanedInvite() async {
        // 情境 A：owner 進 07 → onAppear 查詢在飛 → RTT 內按下「產生邀請碼」。舊寫法在這個
        // 窗口裡 `latestInvite` 仍是 nil，`createInvite` 的 revoke 分支被跳過，平白多建一支
        // DB 裡永遠撤不掉的碼（查詢回來後還會用查到的舊碼覆寫掉它，讓它從畫面上消失）。這裡
        // 用可控 gate 卡住查詢，驗證查詢還在飛的時候 `createInvite` 直接被 guard 擋下、
        // 完全不呼叫底層 API。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()

        let createCallCount = OSAllocatedUnfairLock(initialState: 0)
        let unexpectedRecord = makeInviteRecord(code: "SHOULD-NOT-HAPPEN")
        stub.setCreateInviteHandler { _, _, _, _ in
            createCallCount.withLock { $0 += 1 }
            return unexpectedRecord
        }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setFetchLatestActiveInviteHandler { _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return nil
        }

        let lookupTask = Task { await store.refreshLatestInvite() }
        var guardIterations = 0
        while store.lookupInviteState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 lookupInviteState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let code = await store.createInvite(role: .member)

        XCTAssertNil(code, "查詢還在飛的時候，產生邀請碼必須被擋下")
        XCTAssertEqual(createCallCount.withLock { $0 }, 0, "不該呼叫底層 API，避免建立一支永遠撤不掉的孤兒碼")

        gateContinuation.finish()
        _ = await lookupTask.value
    }

    func test_refreshLatestInvite_whileCreateInviteInFlight_isBlockedAndDoesNotOverwriteNewInvite() async {
        // 對稱方向：`createInvite` 在跑的時候呼叫 `refreshLatestInvite`，必須被擋下，不能用
        // 查詢到的舊值（或 nil）覆寫掉即將由 `createInvite` 寫入的新碼。
        let stub = StubFamilyAPIClient()
        let family = makeFamily()
        stub.setFetchMyFamilyHandler { family }
        let store = FamilyStore(apiClient: stub)
        await store.refreshMyFamily()

        let lookupCallCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchLatestActiveInviteHandler { _ in
            lookupCallCount.withLock { $0 += 1 }
            return nil
        }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let newRecord = makeInviteRecord(code: "NEW999")
        stub.setCreateInviteHandler { _, _, _, _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return newRecord
        }

        let createTask = Task { await store.createInvite(role: .member) }
        var guardIterations = 0
        while store.createInviteState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 createInviteState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let lookupResult = await store.refreshLatestInvite()

        XCTAssertNil(lookupResult, "產生還在飛的時候，查詢必須被擋下，直接回傳目前值（此時是 nil）")
        XCTAssertEqual(lookupCallCount.withLock { $0 }, 0, "不該呼叫底層 API")

        gateContinuation.finish()
        let code = await createTask.value
        XCTAssertEqual(code, "NEW999")
        XCTAssertEqual(store.latestInvite?.code, "NEW999", "被擋下的查詢不該影響 createInvite 正常寫入新碼")
    }

    func test_refreshLatestInvite_familyChangedDuringQuery_discardsStaleResultWithoutStickingInSubmitting() async {
        // R2 N1 建議修法第 2 點的更窄變體：A 的查詢在飛，B 在同一台裝置登入（`syncOwner` 已經
        // `reset()` 過）才回來——不能把 A 查到的碼寫進 B 的 store，也不能讓丟棄的結果把
        // `lookupInviteState` 卡在 `.submitting`（那會讓 B 之後永遠按不到「產生邀請碼」）。
        let stub = StubFamilyAPIClient()
        let familyA = makeFamily(name: "陳家")
        let familyB = makeFamily(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "林家")
        let userA = UUID()
        let userB = UUID()
        let currentFamily = OSAllocatedUnfairLock<Family?>(initialState: familyA)
        stub.setFetchMyFamilyHandler { currentFamily.withLock { $0 } }
        let store = FamilyStore(apiClient: stub)
        _ = await store.syncOwner(to: userA)

        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let staleRecordForFamilyA = makeInviteRecord(code: "STALE-A")
        stub.setFetchLatestActiveInviteHandler { _ in
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return staleRecordForFamilyA
        }

        let lookupTask = Task { await store.refreshLatestInvite() }
        var guardIterations = 0
        while store.lookupInviteState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 lookupInviteState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        currentFamily.withLock { $0 = familyB }
        _ = await store.syncOwner(to: userB)
        XCTAssertEqual(store.myFamily, familyB, "前置條件：B 已經登入並查到自己的家庭")

        gateContinuation.finish()
        _ = await lookupTask.value

        XCTAssertNil(store.latestInvite, "A 查到的碼不能被寫進 B 的 store")
        XCTAssertEqual(
            store.lookupInviteState, .idle,
            "過期結果丟棄後不該卡在 .submitting，否則 B 永遠按不到產生鈕"
        )
    }
}
