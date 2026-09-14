import Foundation
@testable import LittleSprout
import XCTest

/// LS-266（池 `d351af55`，merge-review LS-126 R2 r2-m1）：`TimelineStore.refresh` 同參數重入
/// 去重。跟 `TimelineStoreTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`／`file_length`（同 `TimelineStoreVideoTests.swift`／
/// `TimelineStoreDeleteDiaryTests.swift` 的既有拆檔理由與寫法）。
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
}
