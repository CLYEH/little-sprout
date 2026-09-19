import Foundation
@testable import LittleSprout
import XCTest

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

    /// race：時間軸在畫面上時，批次完成通知（去抖後）與使用者同時下拉刷新要合流成一次真的
    /// 請求，不能各自發——`handleImportBatchMediaUploaded` 呼叫 `refresh(familyID:childID:)`
    /// 刻意不 force，沿用 LS-266 既有 in-flight 合流（見 `TimelineStore+Import.swift` 檔頭
    /// 文件註解）。mutation（改成 `force: true`）：`fetchPointersCalls.count` 會變成 2。
    func test_handleImportBatchMediaUploaded_concurrentWithPullToRefresh_dedupesToSingleAPICall() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        stub.setFetchPointersHandler { _, _, _, _ in
            await gate.wait()
            return []
        }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        store.importRefresh.debounceDelay = {}
        store.screenDidAppear()

        let pullToRefresh = Task { await store.refresh(familyID: familyID, childID: nil) }
        await gate.waitForWaiters(count: 1)
        let importTriggered = store.handleImportBatchMediaUploaded()
        await gate.open()
        _ = await (pullToRefresh.value, importTriggered.value)

        XCTAssertEqual(stub.fetchPointersCalls.count, 1, "同時發生的下拉刷新與批次完成通知應該合流成一次請求")
    }
}
