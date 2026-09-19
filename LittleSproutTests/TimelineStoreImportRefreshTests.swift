import Foundation
@testable import LittleSprout
import os
import XCTest

/// 測試專用、可跨並行情境安全存取的小盒子——模擬「伺服器在請求開始那一刻的狀態」，供下面
/// 兩支 M1 回歸測試的 stub handler 讀（同 `TimelineStoreRefreshDedupTests.swift`
/// `SendableFlagBox` 的既有作法，這裡多一個語意明確的名字）。
private final class ServerSnapshotState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func markLastPhotoLanded() { lock.withLock { $0 = true } }
    var hasLastPhoto: Bool { lock.withLock { $0 } }
}

/// LS-328（源自 LS-315 R3 `957707ef` 風險 1）：批次匯入完成後時間軸去抖刷新／不在畫面上補
/// refresh——`TimelineStoreTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `file_length`（同 `TimelineStoreRefreshDedupTests.swift` 既有拆檔理由與寫法）。
@MainActor
extension TimelineStoreTests {
    /// 核心釘樁：同一批次密集完成的多張照片（`handleImportBatchMediaUploaded` 密集呼叫）只想
    /// 觸發一次真的 refresh——三次呼叫各自用獨立的 `AsyncGate` 卡住去抖等待，**逐一**釋放且
    /// 等前一個呼叫的 Task 真的跑完才釋放下一個（`await first.value` 才 `gate2.open()`）：
    /// 不能三個一起放行——那樣即使拿掉 token 比對，三次 `refresh()` 幾乎同時發起也會被既有
    /// in-flight 合流（LS-266）意外救回、掩蓋掉這支 mutation（見 handoff 記錄）。逐一釋放
    /// 讓「該不該真的呼叫 refresh」完全由 token 比對決定，不摻雜 in-flight 合流。mutation
    /// （拿掉 token 比對）：三次呼叫會各自完整跑完 `refresh`，`fetchPointersCalls` 的 delta
    /// 變成 3，這裡的斷言（`== 1`）會轉紅。
    func test_handleImportBatchMediaUploaded_multipleCallsBeforeDelayResolves_refreshesExactlyOnce() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        _ = await store.refresh(familyID: familyID, childID: nil)
        let callsBeforeBatch = stub.fetchPointersCalls.count
        store.screenDidAppear()

        let gate1 = AsyncGate()
        store.importRefresh.debounceDelay = { await gate1.wait() }
        let first = store.handleImportBatchMediaUploaded()
        await gate1.waitForWaiters(count: 1)

        let gate2 = AsyncGate()
        store.importRefresh.debounceDelay = { await gate2.wait() }
        let second = store.handleImportBatchMediaUploaded()
        await gate2.waitForWaiters(count: 1)

        let gate3 = AsyncGate()
        store.importRefresh.debounceDelay = { await gate3.wait() }
        let third = store.handleImportBatchMediaUploaded()
        await gate3.waitForWaiters(count: 1)

        await gate1.open()
        await first.value
        await gate2.open()
        await second.value
        await gate3.open()
        await third.value

        XCTAssertEqual(
            stub.fetchPointersCalls.count - callsBeforeBatch, 1,
            "同一批次密集完成的多張照片只該真的 refresh 一次，不是每張都打一次"
        )
    }

    /// 核心釘樁：時間軸不在畫面上（`screenDidAppear()` 未呼叫過）時，批次完成不該直接打
    /// API，只該標記 `isDirty`——mutation（拿掉 `isOnScreen` 分支、一律直接 refresh）：
    /// `fetchPointersCalls` 的 delta 會變成 1，這裡的斷言（`== 0`）轉紅。
    func test_handleImportBatchMediaUploaded_offScreen_marksDirtyInsteadOfRefreshing() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        _ = await store.refresh(familyID: familyID, childID: nil)
        let callsBeforeBatch = stub.fetchPointersCalls.count
        store.importRefresh.debounceDelay = {}

        await store.handleImportBatchMediaUploaded().value

        XCTAssertTrue(store.importRefresh.isDirty, "畫面外完成應該標記 isDirty，不直接打 API")
        XCTAssertEqual(stub.fetchPointersCalls.count - callsBeforeBatch, 0, "畫面外完成不該多打一次請求")
    }

    /// 核心釘樁：`screenDidAppear()` 發現 `isDirty` 為 true 時要補一次 refresh 並清旗標——
    /// mutation（拿掉這段 guard／refresh）：`isDirty` 不會被清掉、`fetchPointersCalls` 的
    /// delta 會是 0，這裡的兩個斷言都會轉紅。
    func test_screenDidAppear_whenDirty_triggersRefreshAndClearsFlag() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        _ = await store.refresh(familyID: familyID, childID: nil)
        let callsBeforeAppear = stub.fetchPointersCalls.count
        store.importRefresh.isDirty = true

        await store.screenDidAppear()?.value

        XCTAssertFalse(store.importRefresh.isDirty, "回到畫面補刷新後應該清掉 isDirty")
        XCTAssertEqual(
            stub.fetchPointersCalls.count - callsBeforeAppear, 1, "isDirty 時 screenDidAppear 應該補一次 refresh"
        )
    }

    /// **M1（merge-review R1，PR #505）核心釘樁**：去抖到期的 `refresh` 不 force，可能合流進
    /// 「發起於這張照片落地之前」的舊一輪——LS-266 R2 B1 的世代比對只擋「已被淘汰的世代」，
    /// 擋不下「同世代、但發起時間早於這次伺服器端狀態改變」（同 `refreshWithCurrentFilter()`
    /// 文件註解 LS-266 R2 i1 那句話）。若合流後不補救，最後一張要等下次手動下拉才出現——
    /// 正是本票要修的那個現象，這裡的斷言直接釘住「使用者最終看得到」這件事。
    ///
    /// 情境：①「倒數第二張」完成觸發第一輪 refresh，卡在 handler 裡（那一刻伺服器還沒有
    /// 最後一張）；②卡著的時候最後一張真的落地；③批次完成通知（`debounceDelay` 是空操作，
    /// 立即觸發）合流進①那一輪（`generation` 不會因合流而遞增）；④開閘讓①完成（拿到不含
    /// 最後一張的舊快照）——若沒有 M1 修法，流程到此結束，entries 永遠不含最後一張。
    /// mutation（拿掉 `if generation == generationBefore { await refresh(force: true) }`
    /// 那段）：這裡的斷言會轉紅。
    func test_handleImportBatchMediaUploaded_mergesIntoStaleInFlightRound_forcesFollowUpToIncludeLatestPhoto() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        _ = await store.refresh(familyID: familyID, childID: nil)
        store.importRefresh.debounceDelay = {}
        store.screenDidAppear()

        let gate = AsyncGate()
        let state = ServerSnapshotState()
        let lastPhotoID = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            // 在請求開始那一刻對伺服器狀態取快照（同 `await` 前先讀），才能模擬「這一輪發起
            // 時伺服器還沒有最後一張」——不是請求完成那一刻。
            let hasLast = state.hasLastPhoto
            await gate.wait()
            guard hasLast else { return [] }
            return [TimelineFeedPointer(kind: .media, refId: lastPhotoID, occurredAt: Date(), childIds: [])]
        }

        // ①：卡在 handler 裡，此刻伺服器還沒有最後一張。
        let staleRound = store.handleImportBatchMediaUploaded()
        await gate.waitForWaiters(count: 1)

        // ②：最後一張這時落地。③：批次完成通知合流進①。
        state.markLastPhotoLanded()
        let finalNotification = store.handleImportBatchMediaUploaded()

        // ④：放行①，讓合流與（若 M1 修法在）補救的 force 都跑完。
        await gate.open()
        _ = await (staleRound.value, finalNotification.value)

        XCTAssertTrue(
            store.entries.map(\.refId).contains(lastPhotoID),
            "批次完成後即使合流到照片落地前發起的舊一輪，使用者最終也要看到最後一張，不能停在舊快照"
        )
    }

    /// race（依 M1 修法後的新語意重寫，原本斷言「只打一次」——那條斷言釘住的其實是 M1 的
    /// 缺陷本身：使用者下拉刷新先發起、最後一張緊接著落地時，若堅持「只打一次」就等於堅持
    /// 用下拉當下的舊快照，使用者看不到最後一張）：時間軸在畫面上時，批次完成通知（去抖後）
    /// 與使用者下拉刷新併發——合流成一次請求本身沒問題（沿用 LS-266 既有 in-flight 合流），
    /// 但若最後一張在合流之後才落地，必須再補一次才能讓使用者看到；請求數要有上界（不是
    /// 每次都無限重打）。mutation（拿掉 M1 修法的補救段）：第一個斷言（看得到最後一張）轉紅。
    func test_handleImportBatchMediaUploaded_concurrentWithPullToRefresh_lastPhotoVisibleWithBoundedRequests() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        let state = ServerSnapshotState()
        let lastPhotoID = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            let hasLast = state.hasLastPhoto
            await gate.wait()
            guard hasLast else { return [] }
            return [TimelineFeedPointer(kind: .media, refId: lastPhotoID, occurredAt: Date(), childIds: [])]
        }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        store.importRefresh.debounceDelay = {}
        store.screenDidAppear()

        // 使用者下拉刷新先發起——此刻最後一張還沒落地。
        let pullToRefresh = Task { await store.refresh(familyID: familyID, childID: nil) }
        await gate.waitForWaiters(count: 1)

        // 最後一張這時落地，批次完成通知緊接著觸發——合流進下拉刷新那一輪。
        state.markLastPhotoLanded()
        let importTriggered = store.handleImportBatchMediaUploaded()

        await gate.open()
        _ = await (pullToRefresh.value, importTriggered.value)

        XCTAssertTrue(
            store.entries.map(\.refId).contains(lastPhotoID),
            "批次完成通知與下拉刷新併發時，最後一張最終也要出現，不能停在下拉當下（合流時）的舊快照"
        )
        XCTAssertLessThanOrEqual(
            stub.fetchPointersCalls.count, 2,
            "去抖合流之後的補救最多只該再多打一次請求（下拉本身一次＋必要時補一次），不是無限重打"
        )
    }
}
