import Foundation

/// 非同步測試共用的手動閘門——讓 stub handler 卡在「還在 in-flight」直到測試主動放行，用來
/// 精準控制併發測試裡「誰先完成」，不用 `Task.sleep`／裸 `Task.yield` 猜時間（同
/// `StubTimelineAPIClient`／`StubEULAAPIClient` 的 stub 模式，見該檔）。
///
/// LS-214：原本 `TimelineStoreTests.swift`／`EULAStoreTests.swift` 各自宣告一份逐字相同的
/// `private actor AsyncGate`（merge-review R2 m5 佇列化），抽成這支共用檔；同時新增
/// `waitForWaiters(count:)`——`TimelineStoreTests.
/// test_refresh_secondCallWithDifferentChildID_winsOverStaleInFlightCall` 原本用「等
/// `store.refreshState` 翻成 `.submitting`」當同步點，在 CI 隨機紅：`TimelineAPIClient` 是
/// `protocol: Sendable` existential、`StubTimelineAPIClient` 是 plain class（非 actor），
/// `@MainActor` 的 `TimelineStore.refresh` 呼叫 `apiClient.fetchTimelinePointers(...)` 這一跳
/// 會讓 stub 內部 `box.append(call)` 實際落在併發 executor 上執行——跟 MainActor 這側先做完
/// 的 `refreshState = .submitting` 賦值之間**沒有 happens-before 保證**：兩次獨立呼叫各自的
/// `box.append` 有時會以相反順序完成，讓 `stub.fetchPointersCalls.last` 有機率仍是第一次呼叫
/// 的紀錄。改成等 `gate.waitForWaiters(count:)`，一旦回傳就代表 stub handler 真的執行到
/// `await gate.wait()` 那一行——而 `box.append(call)` 是同一次函式呼叫裡**在它之前**的同步
/// 步驟，因此有真正的 program-order 保證已經完成，才是正確的同步點。
actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    /// `continuations` 是佇列（不是單一變數）：`open()` 時把所有等待者一起放行，第二個等待者
    /// 進來不會覆蓋掉第一個尚未被喚醒的 continuation（merge-review R2 m5 診斷過的掛住成因，
    /// 見 LS-190 comment `3dff2b6e`）。
    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    /// 等到至少有 `count` 個呼叫者卡在 `wait()` 上（尚未被 `open()` 放行）——LS-214：作為明確
    /// 同步點使用，取代猜時間的 `Task.yield()` 迴圈。一旦這裡回傳，代表對應的 `wait()` 呼叫端
    /// 在呼叫 `wait()` 之前的所有步驟都已經真的執行完（program order 保證），可以安全地接著
    /// 做下一步斷言或觸發另一個呼叫。
    func waitForWaiters(count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }
}
