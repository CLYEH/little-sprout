import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-216：`TimelineStore` 愛心反應（`reactionStates`）三支行為——批次計數合併（一頁最多 3 次
/// `get_reaction_counts` 呼叫，一種 kind 一次，不逐卡呼叫）、`toggleReaction` 樂觀更新／失敗
/// 回滾、連點去重（in-flight 期間忽略）。
@MainActor
final class TimelineStoreReactionTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - 批次計數合併（票文 scope 2：三型各一次，不逐卡）

    func test_refresh_loadsReactionCounts_batchedPerKind_notPerCard() async {
        let stub = StubTimelineAPIClient()
        let diaryIDs = [UUID(), UUID()]
        let albumID = UUID()
        let mediaID = UUID()
        let pointers =
            diaryIDs.map { TimelineFeedPointer(kind: .diary, refId: $0, occurredAt: Date(), childIds: []) }
            + [TimelineFeedPointer(kind: .album, refId: albumID, occurredAt: Date(), childIds: [])]
            + [TimelineFeedPointer(kind: .media, refId: mediaID, occurredAt: Date(), childIds: [])]
        stub.setFetchPointersHandler { _, _, _, _ in pointers }
        stub.setReactionCountsHandler { _, targetType, targetIDs in
            switch targetType {
            case "diary": return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 2, reactedByMe: false) }
            case "album": return [ReactionCountRow(targetID: albumID, reactionCount: 5, reactedByMe: true)]
            default: return []
            }
        }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: nil)

        // 四個 target（2 diary＋1 album＋1 media）——若逐卡查會是 4 次，這裡斷言只有 3 次
        // （一種 kind 一次：diary／album／media 各一次，media 那次雖然回傳空陣列，仍算一次
        // 呼叫，因為批次是依 kind 分組，不是依「有沒有結果」決定要不要呼叫）。
        XCTAssertEqual(stub.reactionCountsCalls.count, 3, "同一頁應只呼叫 3 次（一種 kind 一次），不逐卡呼叫")
        let diaryCall = stub.reactionCountsCalls.first { $0.targetType == "diary" }
        XCTAssertEqual(Set(diaryCall?.targetIDs ?? []), Set(diaryIDs), "diary 那一次呼叫要一次帶齊兩個 target_id")
        XCTAssertEqual(store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: diaryIDs[0])).count, 2)
        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .album, refId: albumID)),
            ReactionState(count: 5, reactedByMe: true)
        )
        // media 那次呼叫回傳空陣列——沒有出現在回傳列裡的 target 一律視為 .zero（docs/API.md
        // `get_reaction_counts` 既有慣例），不是遺漏。
        XCTAssertEqual(store.reactionState(forKey: TimelineEntry.id(kind: .media, refId: mediaID)), .zero)
    }

    /// 愛心是次要資訊——`get_reaction_counts` 失敗不該讓整頁時間軸都載入失敗（同
    /// `loadVideoDuration` 失敗時靜默降級的既有哲學）。
    func test_refresh_reactionCountsFailure_doesNotFailPageLoad() async {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .diary, refId: refId, occurredAt: Date(), childIds: [])]
        }
        stub.setReactionCountsHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = TimelineStore(apiClient: stub)

        let success = await store.refresh(familyID: familyID, childID: nil)

        XCTAssertTrue(success, "愛心計數失敗不該讓整頁載入失敗")
        XCTAssertEqual(store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: refId)), .zero)
    }

    /// LS-216 R2（merge-review R1 M1）：`refresh` 先寫 `entries`／`refreshState = .success`
    /// 才 `await loadReactionCounts`——這代表 `loadReactionCounts` 是在這支 `refresh` 呼叫
    /// 「還沒返回」的期間才跑，若飛行途中又有更新的 `refresh`（世代號前進），這批遲到的計數
    /// 不能覆寫新世代已經寫好的 `reactionStates`。同 `TimelineStoreTests
    /// .test_refresh_secondCallWithDifferentChildID_winsOverStaleInFlightCall` 既有的
    /// `AsyncGate` 卡住＋世代競態驗證寫法——這裡用 `familyID` 而非 `childID` 分辨兩次呼叫
    /// （`get_reaction_counts` 的參數不含 `childID`，用它分辨會兩次都卡在同一個 gate）。
    func test_refresh_staleReactionCountsFromSupersededRefresh_areDiscarded() async {
        let stub = StubTimelineAPIClient()
        let staleFamilyID = UUID()
        let freshFamilyID = UUID()
        let diaryID = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [])]
        }
        let gate = AsyncGate()
        stub.setReactionCountsHandler { queriedFamilyID, _, targetIDs in
            if queriedFamilyID == staleFamilyID {
                await gate.wait()
                // 舊世代的計數——沒有世代檢查的話，這批遲到的資料會覆寫新世代已經寫好的值。
                return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 99, reactedByMe: true) }
            }
            return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 1, reactedByMe: false) }
        }
        let store = TimelineStore(apiClient: stub)

        let staleCall = Task { await store.refresh(familyID: staleFamilyID, childID: nil) }
        await gate.waitForWaiters(count: 1)

        let freshSucceeded = await store.refresh(familyID: freshFamilyID, childID: nil)
        XCTAssertTrue(freshSucceeded)
        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: diaryID)),
            ReactionState(count: 1, reactedByMe: false),
            "新世代 refresh 自己的計數應該先寫好"
        )

        await gate.open()
        _ = await staleCall.value

        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: diaryID)),
            ReactionState(count: 1, reactedByMe: false),
            "舊世代遲到的計數（count 99）不能覆寫新世代已經寫好的值"
        )
    }

    /// R3（merge-review R2 minor-1）：某 target 的愛心數掉到 0 時，`get_reaction_counts` 不會
    /// 再回傳該列（伺服器省略＝0，同 `get_reaction_counts` 既有慣例，見上面
    /// `test_refresh_loadsReactionCounts_batchedPerKind_notPerCard` media 那段的斷言）——但
    /// 這不是「這次沒查到新資料所以維持原狀」，而是「這次請求範圍內的 target 明確查到 0
    /// 筆」，`reactionStates` 必須跟著歸零，不能保留上一輪的舊值，否則家人收回讚之後，其他人
    /// 的卡片會一直卡在舊的數字，直到 app 重啟（`reactionStates` 只在 `reset()` 才會清空）。
    func test_refresh_targetMissingFromSecondReactionCountsResponse_resetsToZero() async {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .diary, refId: refId, occurredAt: Date(), childIds: [])]
        }
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setReactionCountsHandler { _, _, targetIDs in
            let thisCall = callCount.withLock { count -> Int in
                count += 1
                return count
            }
            if thisCall == 1 {
                return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 1, reactedByMe: false) }
            }
            // 第二次刷新：家人收回了唯一一個讚，伺服器不再回傳這個 target 的列。
            return []
        }
        let store = TimelineStore(apiClient: stub)

        await store.refresh(familyID: familyID, childID: nil)
        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: refId)),
            ReactionState(count: 1, reactedByMe: false),
            "第一次刷新：伺服器回報 1 個讚"
        )

        await store.refresh(familyID: familyID, childID: nil)

        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .diary, refId: refId)),
            .zero,
            "第二次刷新伺服器省略了這個 target（＝目前 0 個讚），必須把舊的 count 1 蓋掉，"
                + "不能誤判成「這次沒新資料所以維持原狀」而一直停在 1"
        )
    }

    // MARK: - R4（merge-review R3 F1／F2）：失敗降級與飛行中樂觀更新的保護

    /// F1：某個 kind 的 `get_reaction_counts` 這次請求**失敗**（不是「查成功但沒有任何列」）
    /// 時，這個 kind 底下既有的 `reactionStates` 必須維持原狀，不可被誤判成「伺服器說 0」而
    /// 洗成 `.zero`——同一批請求裡查詢成功的其他 kind 仍要正常寫回。若這支測試被移除
    /// `succeededKinds` 過濾（改回 `(try? ...) ?? []`），diary 那個既有值會被寫成 `.zero`，
    /// 此斷言會轉紅。
    func test_refresh_oneKindReactionCountsFails_preservesExistingStateForThatKindOnly() async {
        let stub = StubTimelineAPIClient()
        let diaryID = UUID()
        let albumID = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [
                TimelineFeedPointer(kind: .diary, refId: diaryID, occurredAt: Date(), childIds: []),
                TimelineFeedPointer(kind: .album, refId: albumID, occurredAt: Date(), childIds: [])
            ]
        }
        stub.setReactionCountsHandler { _, targetType, targetIDs in
            if targetType == "diary" { throw AppError.network(message: "offline") }
            return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 7, reactedByMe: true) }
        }
        let store = TimelineStore(apiClient: stub)
        let diaryKey = TimelineEntry.id(kind: .diary, refId: diaryID)
        let existing = ReactionState(count: 5, reactedByMe: true)
        store.seedReactionState(existing, forKey: diaryKey)

        await store.refresh(familyID: familyID, childID: nil)

        XCTAssertEqual(
            store.reactionState(forKey: diaryKey), existing,
            "diary 這次查詢失敗——既有的愛心狀態不能被洗成 .zero，也不能是使用者自己的讚被誤刪"
        )
        XCTAssertEqual(
            store.reactionState(forKey: TimelineEntry.id(kind: .album, refId: albumID)),
            ReactionState(count: 7, reactedByMe: true),
            "album 查詢成功——不受 diary 那個 kind 失敗影響，照樣正常寫回"
        )
    }

    /// F2：使用者按讚的 RPC 還在飛行中（`togglingReactionKeys` 內）時，同時有一個批次刷新的
    /// `get_reaction_counts` 回應回來（伺服器快照早於這次按讚，省略了這個 target）——這個
    /// target 的樂觀更新不能被歸零。用兩個 `AsyncGate` 精準卡住兩支 handler 的完成順序，不猜
    /// 時間（見 `AsyncGate` 文件註解 LS-214 教訓）。若這支測試被移除 `togglingReactionKeys`
    /// 跳過寫回那行，中段斷言會轉紅。
    func test_refresh_inFlightToggleReaction_isNotZeroedByConcurrentBatchRefresh() async throws {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .diary, refId: refId, occurredAt: Date(), childIds: [])]
        }
        let countsGate = AsyncGate()
        stub.setReactionCountsHandler { _, _, _ in
            await countsGate.wait()
            return []
        }
        let toggleGate = AsyncGate()
        stub.setToggleReactionHandler { _, _, _ in
            await toggleGate.wait()
            return true
        }
        let store = TimelineStore(apiClient: stub)
        let key = TimelineEntry.id(kind: .diary, refId: refId)

        let refreshTask = Task { await store.refresh(familyID: familyID, childID: nil) }
        await countsGate.waitForWaiters(count: 1)

        let toggleTask = Task { try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID) }
        await toggleGate.waitForWaiters(count: 1)
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 1, reactedByMe: true),
            "toggle 的樂觀更新應該已經先落地"
        )

        // 放行批次刷新的回應——伺服器快照沒有這個 target，但它正在 togglingReactionKeys 內。
        await countsGate.open()
        _ = await refreshTask.value
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 1, reactedByMe: true),
            "in-flight 的樂觀更新不能被同時進行的批次刷新歸零"
        )

        await toggleGate.open()
        try await toggleTask.value
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 1, reactedByMe: true),
            "toggle RPC 確認完成後，最終狀態仍應是使用者剛按下的這顆讚"
        )
    }

    /// LS-237 修（池 `37be169f` m2）驗收「競窗計數＝伺服器值 ±1」：首載一個 RTT 競窗內按讚
    /// （票文原例）——伺服器這批查詢的快照早於使用者這次按讚（`reactedByMe: false`，這則
    /// 內容原本已經有其他人按的 4 個讚），本地樂觀更新已經先落地成 `(count: 1, reactedByMe:
    /// true)`（`previous` 預設 `.zero`，還沒收到任何批次計數）。修正前這批查詢整筆
    /// `continue`，最終停在錯誤的樂觀值 1；修正後應該用伺服器快照 4 校正成 4+1=5——這才是
    /// 「若快照也反映了使用者這次切換」的正確值。
    func test_refresh_inFlightToggleReaction_countCorrectedByServerSnapshotPlusOne() async throws {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setFetchPointersHandler { _, _, _, _ in
            [TimelineFeedPointer(kind: .diary, refId: refId, occurredAt: Date(), childIds: [])]
        }
        let countsGate = AsyncGate()
        stub.setReactionCountsHandler { _, _, targetIDs in
            await countsGate.wait()
            return targetIDs.map { ReactionCountRow(targetID: $0, reactionCount: 4, reactedByMe: false) }
        }
        let toggleGate = AsyncGate()
        stub.setToggleReactionHandler { _, _, _ in
            await toggleGate.wait()
            return true
        }
        let store = TimelineStore(apiClient: stub)
        let key = TimelineEntry.id(kind: .diary, refId: refId)

        let refreshTask = Task { await store.refresh(familyID: familyID, childID: nil) }
        await countsGate.waitForWaiters(count: 1)

        let toggleTask = Task { try await store.toggleReaction(kind: .diary, refId: refId, familyID: familyID) }
        await toggleGate.waitForWaiters(count: 1)
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 1, reactedByMe: true),
            "toggle 的樂觀更新應該已經先落地（前提還沒收到任何伺服器計數）"
        )

        // 放行批次刷新的回應——伺服器快照回報 4（`reactedByMe: false`，還沒反映使用者這次
        // 切換），跟本地樂觀值 `reactedByMe: true` 不一致，count 應該校正成 4+1=5。
        await countsGate.open()
        _ = await refreshTask.value
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 5, reactedByMe: true),
            "count 應該用伺服器快照校正成 4+1=5，不是停在樂觀更新當下猜的 1"
        )

        await toggleGate.open()
        try await toggleTask.value
        XCTAssertEqual(
            store.reactionState(forKey: key), ReactionState(count: 5, reactedByMe: true),
            "toggle RPC 確認完成後 reactedByMe 不變，count 維持批次刷新校正後的 5"
        )
    }
}
