import Foundation
@testable import LittleSprout
import XCTest

/// `TimelineStore.toggleReaction`——樂觀更新／失敗回滾／連點去重（LS-216 票文 scope 2）。
/// 抽成獨立檔案（同 `TimelineStoreReactionTests` 拆分理由：LS-237 加測試後那支檔案逼近
/// SwiftLint `type_body_length` 上限）。
@MainActor
final class TimelineStoreToggleReactionTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - toggleReaction：樂觀更新／失敗回滾（票文 scope 2）

    func test_toggleReaction_fromUnliked_optimisticallyLikesAndConfirms() async throws {
        let stub = StubTimelineAPIClient()
        stub.setToggleReactionHandler { _, _, _ in true }
        let store = TimelineStore(apiClient: stub)
        let refId = UUID()

        try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID)

        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: refId)),
            ReactionState(count: 1, reactedByMe: true)
        )
        XCTAssertEqual(stub.toggleReactionCalls.count, 1)
        XCTAssertEqual(stub.toggleReactionCalls.first?.targetType, "diary")
        XCTAssertEqual(stub.toggleReactionCalls.first?.targetID, refId)
    }

    func test_toggleReaction_fromLiked_optimisticallyUnlikesAndDecrementsCount() async throws {
        let stub = StubTimelineAPIClient()
        stub.setToggleReactionHandler { _, _, _ in false }
        let store = TimelineStore(apiClient: stub)
        let refId = UUID()
        let key = TimelineEntry.id(kind: .diary, refId: refId)
        store.seedReactionState(ReactionState(count: 3, reactedByMe: true), forKey: key)

        try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID)

        XCTAssertEqual(store.reactionState(forKey: key), ReactionState(count: 2, reactedByMe: false))
    }

    /// 失敗要整個 `ReactionState` 回滾到呼叫前的快照（不是只回滾 `reactedByMe`，計數也要一起
    /// 復原），並把 `AppError` 往外拋讓呼叫端（`InteractionRow`）決定怎麼顯示。
    func test_toggleReaction_failure_rollsBackToPreviousStateAndThrows() async {
        let stub = StubTimelineAPIClient()
        stub.setToggleReactionHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = TimelineStore(apiClient: stub)
        let refId = UUID()
        let key = TimelineEntry.id(kind: .diary, refId: refId)
        store.seedReactionState(ReactionState(count: 3, reactedByMe: false), forKey: key)

        do {
            try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID)
            XCTFail("預期拋出錯誤")
        } catch {
            XCTAssertTrue(error is AppError, "應拋出已映射的 AppError，不是原始 SDK 錯誤型別")
        }

        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 3, reactedByMe: false),
            "失敗要回滾到呼叫前的狀態（count 與 reactedByMe 都要復原）"
        )
    }

    // MARK: - 連點去重（票文 scope 2：in-flight 期間忽略）

    /// 同一個 target 在第一次呼叫還沒完成前又被呼叫第二次——第二次應該安靜忽略（不排隊、
    /// 不重複打 API），同票文「in-flight 期間忽略或序列化」的第一個選項。用 `AsyncGate` 精準
    /// 卡住第一次呼叫在「已經進入 in-flight」但「API 尚未回應」的狀態，避免用 `Task.sleep`／
    /// 裸 `Task.yield` 猜時間（見 `AsyncGate` 文件註解 LS-214 教訓）。
    func test_toggleReaction_secondCallWhileInFlight_isIgnoredNotQueued() async throws {
        let stub = StubTimelineAPIClient()
        let gate = AsyncGate()
        stub.setToggleReactionHandler { _, _, _ in
            await gate.wait()
            return true
        }
        let store = TimelineStore(apiClient: stub)
        let refId = UUID()

        // 用 `Task { }`（不是 `async let`）：後者在 Swift 6 strict concurrency 下對
        // `@MainActor` 測試類別的 `self`（`familyID` 隱含 `self.familyID`）送進子任務會被
        // 判定「sending 'self' risks causing data races」，同 `EULAStoreTests` 既有的
        // `Task { await store... }` 寫法（見該檔文件註解）。
        let firstTask = Task { try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID) }
        // 等到第一次呼叫真的卡在 `await apiClient.toggleReaction`（已經插入
        // `togglingReactionKeys`）才發第二次——program-order 保證，不是猜時間。
        await gate.waitForWaiters(count: 1)
        try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID)
        await gate.open()
        try await firstTask.value

        XCTAssertEqual(stub.toggleReactionCalls.count, 1, "in-flight 期間的第二次呼叫應被忽略，不應真的打第二次 API")
        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: refId)),
            ReactionState(count: 1, reactedByMe: true)
        )
    }
}
