import Foundation
@testable import LittleSprout
import os
import XCTest

/// 測試專用、可跨並行情境安全存取的小盒子——LS-266 R2 M1 探針需要在 `@Sendable` 的 stub
/// handler 閉包裡記一個值、稍後在測試主體讀回來，同 `StubTimelineAPIClient.Box` 的既有作法
/// （`OSAllocatedUnfairLock`），這裡只是單一 `Bool` 用不到整支 stub 那麼多欄位，獨立成一支
/// 輕量版本。
private final class SendableFlagBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func set(_ value: Bool) { lock.withLock { $0 = value } }
    var value: Bool { lock.withLock { $0 } }
}

/// LS-266（池 `d351af55`，merge-review LS-126 R2 r2-m1；R2 訂正 merge-review R1 `443e910f`
/// B1／M1／i2）：`TimelineStore.refresh` 同參數重入去重。跟 `TimelineStoreTests` 是同一個
/// 測試對象，拆成獨立檔案純粹是為了 SwiftLint `type_body_length`／`file_length`（同
/// `TimelineStoreVideoTests.swift`／`TimelineStoreDeleteDiaryTests.swift` 的既有拆檔理由與
/// 寫法）。
@MainActor
extension TimelineStoreTests {
    /// 核心釘樁：同一組篩選參數（`familyID`／`childID`）在 `.task(id:)` 與 `.refreshable`
    /// 幾乎同時觸發時，第二次呼叫必須沿用第一次還在飛的那個 `Task`，不再發第二次
    /// `fetchTimelinePointers`。用 `AsyncGate` 卡住 handler（同 `TimelineStoreTests.swift`
    /// 既有測試的既定手法）：`gate.waitForWaiters(count: 1)` 確保至少有一次呼叫真的卡在
    /// handler 裡（不論去重是否正確都會發生），接著開閘讓兩次呼叫各自收斂——`await
    /// (firstCall.value, secondCall.value)` 會逼 runtime 把兩個 Task 都跑到完成，屆時
    /// `fetchPointersCalls` 才是最終、確定的次數：去重正確只會有 1 次；mutation（拿掉
    /// in-flight registry）會是 2 次。
    func test_refresh_concurrentSameParams_dedupesToSingleAPICall() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        stub.setFetchPointersHandler { _, _, _, _ in
            await gate.wait()
            return []
        }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()

        let firstCall = Task { await store.refresh(familyID: familyID, childID: nil) }
        let secondCall = Task { await store.refresh(familyID: familyID, childID: nil) }
        await gate.waitForWaiters(count: 1)
        await gate.open()
        let (firstResult, secondResult) = await (firstCall.value, secondCall.value)

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(stub.fetchPointersCalls.count, 1, "同參數併發兩次應該只發一次 fetchTimelinePointers")
    }

    /// 對照組：`childID` 不同不該被去重誤傷——兩次同時發起仍要各自真的打一次請求（回傳值不是
    /// 這裡的重點：世代號機制本來就只讓「最後完成」的那次寫回 `true`／`entries`，另一次依既有
    /// 機制安靜回 `false`，這個票不動這個既有行為，見 `TimelineStore.refresh` 世代號文件
    /// 註解）。
    func test_refresh_concurrentDifferentParams_fetchesSeparately() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()
        let otherChildID = UUID()

        let firstCall = Task { await store.refresh(familyID: familyID, childID: nil) }
        let secondCall = Task { await store.refresh(familyID: familyID, childID: otherChildID) }
        _ = await (firstCall.value, secondCall.value)

        XCTAssertEqual(stub.fetchPointersCalls.count, 2, "不同參數即使同時發起，仍各自應該真的發一次請求")
    }

    // MARK: - B1（merge-review R1 `443e910f`）：合流要看世代號，不能合流到已被淘汰的舊一輪

    /// 核心釘樁：A→B→A 快速切換——篩選「全部」（childID=nil）開始 refresh（卡住）；切到寶貝
    /// B（不同 key，世代號推進，立即完成）；再切回「全部」——R1 版的合流只看 key 有沒有在飛，
    /// 會合流到第一次那個世代號已經被 B 淘汰的舊呼叫，它回來時被世代號 guard 丟棄、
    /// `entries` 停在 B 的內容。R2 修法：第三次呼叫發現既有登記的世代號已經落後，另開一輪、
    /// 真的再發一次請求，`entries` 最終正確是 A 的（最新一輪的）內容。
    func test_refresh_thirdCallSameKeyAfterGenerationAdvanced_doesNotJoinStaleTask() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        let pointerA1 = TimelineFeedPointer(kind: .media, refId: UUID(), occurredAt: Date(), childIds: [])
        let pointerA2 = TimelineFeedPointer(kind: .media, refId: UUID(), occurredAt: Date(), childIds: [])
        let pointerB = TimelineFeedPointer(kind: .media, refId: UUID(), occurredAt: Date(), childIds: [])
        let familyID = UUID()
        let childB = UUID()
        stub.setFetchPointersHandler { _, childID, _, _ in
            guard childID == nil else { return [pointerB] }
            // 用「目前已經記錄到的 childID=nil 呼叫次數」分辨這是第一次還是第二次——不是
            // 自己另外維護計數器（那個計數器要跨 @Sendable 閉包安全存取又是另一個問題），
            // `stub.fetchPointersCalls` 在呼叫 handler 前就已經記錄，讀起來天然執行緒安全
            // （`StubTimelineAPIClient` 內部用 `OSAllocatedUnfairLock`）。
            let callIndex = stub.fetchPointersCalls.filter { $0.childID == nil }.count
            if callIndex == 1 {
                await gate.wait()
                return [pointerA1]
            }
            return [pointerA2]
        }
        let store = TimelineStore(apiClient: stub)

        // ① 篩選「全部」開始，卡在 handler 裡。
        let firstA = Task { await store.refresh(familyID: familyID, childID: nil) }
        await gate.waitForWaiters(count: 1)

        // ② 切到寶貝 B——不同 key，世代號推進，立即完成、寫回 B 的內容。
        let bSucceeded = await store.refresh(familyID: familyID, childID: childB)
        XCTAssertTrue(bSucceeded)
        XCTAssertEqual(store.entries.map(\.refId), [pointerB.refId])

        // ③ 切回「全部」——B1 修法前會合流到 ① 那個已經落後世代的 Task；修法後應該另開一輪。
        let secondA = Task { await store.refresh(familyID: familyID, childID: nil) }

        // ④ 放行 ① 那個卡住的舊呼叫——世代號已經落後，回來時該被 guard 丟棄、不寫回 entries。
        await gate.open()
        let firstAResult = await firstA.value
        let secondAResult = await secondA.value

        XCTAssertFalse(firstAResult, "被淘汰的舊世代不該回報成功")
        XCTAssertTrue(secondAResult)
        XCTAssertEqual(
            store.entries.map(\.refId), [pointerA2.refId],
            "PROBE：切回「全部」之後畫面應該是最新一輪的內容，不是被世代號丟棄的舊 Task 結果"
        )
        XCTAssertEqual(
            stub.fetchPointersCalls.filter { $0.childID == nil }.count, 2,
            "世代號已經落後的同 key 呼叫應該另開一輪、真的再發一次請求，不能合流到注定被丟棄的舊 Task"
        )
    }

    // MARK: - M1（merge-review R1 `443e910f`）：發起者的取消要傳到 API client

    /// 核心釘樁：發起一輪 refresh 的呼叫端（例如 `.task(id:)` 篩選條件變了）取消時，取消要
    /// 傳進 `apiClient.fetchTimelinePointers` 內部——R1 版把 `performRefresh` 包進
    /// unstructured `Task {}`，呼叫端取消不會傳進去（`Task.isCancelled` 恆為 false）；R2 讓
    /// 發起者直接在自己的呼叫環境跑 `performRefresh`，取消會自然沿著呼叫鏈傳遞。
    func test_refresh_originatingCallerCancellation_propagatesIntoAPIClient() async {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        let observedCancellation = SendableFlagBox()
        stub.setFetchPointersHandler { _, _, _, _ in
            await gate.wait()
            // PROBE：取消是否已經傳到這裡——R1 版讀到的是 false（沒傳到）。
            observedCancellation.set(Task.isCancelled)
            return []
        }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()

        let task = Task { await store.refresh(familyID: familyID, childID: nil) }
        await gate.waitForWaiters(count: 1)
        task.cancel()
        await gate.open()
        _ = await task.value

        XCTAssertTrue(observedCancellation.value, "發起這一輪的呼叫端取消應該傳到 API client 內部")
    }

    // MARK: - i2（merge-review R1 `443e910f`）：完成後必須清空 in-flight 登記

    /// 核心釘樁：`refresh` 完成後，`hasInFlightRefresh(familyID:childID:)` 必須回 false——不然
    /// 下一次同參數呼叫會誤判成「還在飛」，合流到一個早已解決、不會再 resume 任何人的舊登記，
    /// 永遠卡住（見 `TimelineStore.refresh` 內 `inFlightRefreshes[key] === inFlight` 那段
    /// 文件註解）。用直接狀態斷言（不靠 timeout／第二次呼叫），mutation（拿掉那段清理）會讓
    /// 這裡乾淨轉紅，不會卡死測試本身。
    func test_refresh_afterCompletion_clearsInFlightRegistry() async {
        let stub = StubTimelineAPIClient()
        stub.setFetchPointersHandler { _, _, _, _ in [] }
        let store = TimelineStore(apiClient: stub)
        let familyID = UUID()

        _ = await store.refresh(familyID: familyID, childID: nil)

        XCTAssertFalse(
            store.hasInFlightRefresh(familyID: familyID, childID: nil),
            "完成後應該清空 in-flight 登記，下一次同參數呼叫才會真的再發一次請求"
        )
    }
}
