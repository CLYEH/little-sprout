import Foundation
@testable import LittleSprout
import XCTest

/// 頂層自由函式（非 `CommentsStoreTests` 的 instance method）：`@Sendable` handler closure
/// 不能捕捉 `@MainActor`、非 `Sendable` 的測試類別 `self`，把「組一列留言」抽成不依賴 `self`
/// 的自由函式才能在 `stub.setListCommentsHandler { ... }` 這類 closure 內呼叫。
private let commentsStoreTestsAuthorID = UUID()

private func makeCommentRow(id: UUID, createdAt: Date, body: String = "留言") -> CommentRecord {
    CommentRecord(
        id: id, authorID: commentsStoreTestsAuthorID, authorDisplayName: "陳志明", body: body, createdAt: createdAt
    )
}

/// LS-218：`CommentsStore`——分頁合併去重（首載反轉顯示順序、載入更早防禦性去重）、樂觀插入／
/// 失敗回滾、`hasEarlier` 依回傳筆數是否等於 `pageSize` 判斷（同 `TimelineStore.hasMorePages`
/// 既有慣例）。
@MainActor
final class CommentsStoreTests: XCTestCase {
    private let familyID = UUID()
    private let targetID = UUID()
    private let authorID = commentsStoreTestsAuthorID

    private func makeRow(id: UUID, createdAt: Date, body: String = "留言") -> CommentRecord {
        makeCommentRow(id: id, createdAt: createdAt, body: body)
    }

    private func makeStore(_ stub: StubCommentAPIClient) -> CommentsStore {
        CommentsStore(apiClient: stub, familyID: familyID, targetType: "diary", targetID: targetID)
    }

    // MARK: - 首載：反轉為由舊到新，hasEarlier 依回傳筆數判斷

    func test_loadInitial_reversesServerOrderToOldestFirst() async {
        let stub = StubCommentAPIClient()
        let older = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 100), body: "較舊")
        let newer = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 200), body: "較新")
        // 伺服器回傳 created_at DESC（最新在前）——同 list_comments 既有 keyset 慣例。
        stub.setListCommentsHandler { _, _, _, _, _ in [newer, older] }
        let store = makeStore(stub)

        await store.loadInitial()

        XCTAssertEqual(store.comments.map(\.body), ["較舊", "較新"], "畫面應由舊到新顯示，最新的在最後")
        XCTAssertEqual(store.initialLoadState, .success)
    }

    func test_loadInitial_pageSizeCount_setsHasEarlierTrue() async {
        let stub = StubCommentAPIClient()
        let rows = (0..<CommentsStore.pageSize).map {
            makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        stub.setListCommentsHandler { _, _, _, _, _ in rows }
        let store = makeStore(stub)

        await store.loadInitial()

        XCTAssertTrue(store.hasEarlier, "回傳筆數等於 pageSize 時應假定可能還有更早的")
    }

    func test_loadInitial_fewerThanPageSize_setsHasEarlierFalse() async {
        let stub = StubCommentAPIClient()
        stub.setListCommentsHandler { _, _, _, _, _ in
            [makeCommentRow(id: UUID(), createdAt: Date())]
        }
        let store = makeStore(stub)

        await store.loadInitial()

        XCTAssertFalse(store.hasEarlier, "回傳筆數小於 pageSize 代表這已經是全部")
    }

    func test_loadInitial_failure_mapsToAppError() async {
        let stub = StubCommentAPIClient()
        stub.setListCommentsHandler { _, _, _, _, _ in throw AppError.network(message: "offline") }
        let store = makeStore(stub)

        await store.loadInitial()

        guard case .failure(let error) = store.initialLoadState else {
            return XCTFail("預期 .failure，實際是 \(store.initialLoadState)")
        }
        XCTAssertEqual(error, .network(message: "offline"))
    }

    // MARK: - 載入更早：帶上最舊一則的游標、防禦性去重、插到最前面

    func test_loadEarlier_usesOldestCommentAsCursor_prependsDeduped() async {
        let stub = StubCommentAPIClient()
        let firstPageOldest = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 200), body: "第一批較舊")
        let firstPageNewest = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 300), body: "第一批較新")
        // 首頁要滿 `pageSize` 筆，`hasEarlier` 才會判定「可能還有更早的」（同
        // `test_loadInitial_pageSizeCount_setsHasEarlierTrue` 既有慣例）——中間用填充列補滿，
        // 斷言只看頭尾與筆數，不逐筆列舉填充列。
        let fillers = (0..<(CommentsStore.pageSize - 2)).map {
            makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 201 + Double($0)), body: "填充\($0)")
        }
        stub.setListCommentsHandler { _, _, _, cursor, _ in
            guard let cursor else {
                return [firstPageNewest] + fillers + [firstPageOldest]
            }
            // 第二次呼叫（載入更早）——應該帶上第一批「最舊」那一則（`firstPageOldest`，反轉後
            // 排在 `comments.first`）的游標。
            XCTAssertEqual(cursor.createdAt, firstPageOldest.createdAt)
            XCTAssertEqual(cursor.id, firstPageOldest.id)
            let evenOlder = makeCommentRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 100), body: "更早")
            // 防禦性去重：故意重複回傳第一批已經有的那一則，驗證不會出現兩次。
            return [firstPageOldest, evenOlder]
        }
        let store = makeStore(stub)
        await store.loadInitial()
        XCTAssertTrue(store.hasEarlier)

        await store.loadEarlier()

        XCTAssertEqual(store.comments.first?.body, "更早", "更早的留言應該插到最前面")
        XCTAssertEqual(
            store.comments.count, CommentsStore.pageSize + 1,
            "重複回傳的第一批留言（firstPageOldest）不應該出現第二次，只多了「更早」這一則"
        )
        XCTAssertEqual(store.loadEarlierState, .success)
    }

    /// merge-review R1 m2：`loadEarlier()` 進行中若被 `loadInitial()`（封鎖成功／重試觸發）
    /// 換掉整份 `comments`，稍後才回來的 `loadEarlier()` 舊回應不該把舊頁 prepend 回一份已經
    /// 是新世代的清單，也不該用舊頁筆數覆蓋 `hasEarlier`。
    func test_loadEarlier_supersededByLoadInitial_discardsStaleResult() async {
        let stub = StubCommentAPIClient()
        let firstPageOldest = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 200), body: "第一批較舊")
        let fillers = (0..<(CommentsStore.pageSize - 1)).map {
            makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 201 + Double($0)), body: "填充\($0)")
        }
        stub.setListCommentsHandler { _, _, _, cursor, _ in
            cursor == nil ? fillers + [firstPageOldest] : []
        }
        let store = makeStore(stub)
        await store.loadInitial()
        XCTAssertTrue(store.hasEarlier)

        // 換 handler：loadEarlier（帶游標）與 loadInitial（block 成功後重新首載，無游標）
        // 分別卡在各自的閘門，精準控制「loadInitial 後開始、但先完成」這個 m2 描述的順序。
        let loadEarlierGate = AsyncGate()
        let loadInitialGate = AsyncGate()
        let blockedAuthorRow = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 50), body: "被封鎖者的舊留言")
        let freshAfterBlockRow = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 999), body: "封鎖後的新首頁")
        stub.setListCommentsHandler { _, _, _, cursor, _ in
            if let cursor {
                XCTAssertEqual(cursor.createdAt, firstPageOldest.createdAt)
                await loadEarlierGate.wait()
                return [blockedAuthorRow]
            } else {
                await loadInitialGate.wait()
                return [freshAfterBlockRow]
            }
        }

        // loadEarlier 先開始（世代號還沒被 loadInitial 動過），卡在閘門裡。
        let loadEarlierTask = Task { await store.loadEarlier() }
        while store.loadEarlierState != .submitting { await Task.yield() }

        // loadEarlier 還沒完成時，block 成功觸發的 loadInitial 才起跑（世代號遞增）。
        let loadInitialTask = Task { await store.loadInitial() }
        while store.initialLoadState != .submitting { await Task.yield() }

        // 先放行 loadInitial：完成後 comments 整批換成 [freshAfterBlockRow]。
        await loadInitialGate.open()
        await loadInitialTask.value
        XCTAssertEqual(store.comments.map(\.body), ["封鎖後的新首頁"])
        XCTAssertFalse(store.hasEarlier)

        // 再放行 loadEarlier：世代號已經被 loadInitial 換過，舊回應必須整批丟棄。
        await loadEarlierGate.open()
        await loadEarlierTask.value

        XCTAssertEqual(
            store.comments.map(\.body), ["封鎖後的新首頁"],
            "loadEarlier 的舊回應不該把被封鎖者的留言 prepend 回一份已經是新世代的清單"
        )
        XCTAssertFalse(store.hasEarlier, "loadEarlier 的舊回應不該用舊頁筆數覆蓋 hasEarlier")
        XCTAssertEqual(
            store.loadEarlierState, .idle,
            "被丟棄的 loadEarlier 要把 loadEarlierState 收回 .idle，不然「載入更早的留言」鈕會卡在永久轉圈"
        )
    }

    func test_loadEarlier_whenNoMoreEarlier_doesNotCallAPI() async {
        let stub = StubCommentAPIClient()
        stub.setListCommentsHandler { _, _, _, _, _ in [makeCommentRow(id: UUID(), createdAt: Date())] }
        let store = makeStore(stub)
        await store.loadInitial()
        XCTAssertFalse(store.hasEarlier)

        await store.loadEarlier()

        XCTAssertEqual(stub.listCommentsCalls.count, 1, "hasEarlier 為 false 時不應該再打第二次 API")
    }

    // MARK: - 送出：樂觀插入／成功換上真正 id／失敗回滾

    func test_send_optimisticallyAppends_thenReplacesTempIDWithServerID() async {
        let stub = StubCommentAPIClient()
        let serverID = UUID()
        let gate = AsyncGate()
        stub.setCreateCommentHandler { _, _, _, _ in
            await gate.wait()
            return serverID
        }
        let store = makeStore(stub)

        let sendTask = Task { await store.send(body: "太可愛了", authorID: authorID, authorDisplayName: "我") }
        await gate.waitForWaiters(count: 1)

        XCTAssertEqual(store.comments.count, 1, "RPC 還在飛行中——樂觀插入應該已經先出現在畫面上")
        let optimisticID = store.comments[0].id
        XCTAssertNotEqual(optimisticID, serverID, "飛行中應該還是暫時 id")

        await gate.open()
        let success = await sendTask.value

        XCTAssertTrue(success)
        XCTAssertEqual(store.comments.count, 1)
        XCTAssertEqual(store.comments[0].id, serverID, "成功後暫時 id 應換成伺服器回傳的真正 id")
        XCTAssertEqual(store.sendState, .idle)
    }

    func test_send_failure_rollsBackOptimisticInsert() async {
        let stub = StubCommentAPIClient()
        stub.setCreateCommentHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = makeStore(stub)

        let success = await store.send(body: "太可愛了", authorID: authorID, authorDisplayName: "我")

        XCTAssertFalse(success)
        XCTAssertTrue(store.comments.isEmpty, "失敗要把樂觀插入的那一則整個移除，不留殘影")
        guard case .failure = store.sendState else {
            return XCTFail("預期 sendState 為 .failure，實際是 \(store.sendState)")
        }
    }

    func test_send_blankBody_doesNotCallAPI_orMutateState() async {
        let stub = StubCommentAPIClient()
        let store = makeStore(stub)

        let success = await store.send(body: "   \n  ", authorID: authorID, authorDisplayName: "我")

        XCTAssertFalse(success)
        XCTAssertTrue(store.comments.isEmpty)
        XCTAssertEqual(stub.createCommentCalls.count, 0, "空白內容不應該真的打 API")
        XCTAssertEqual(store.sendState, .idle, "短路路徑不應該把 sendState 動到 .submitting")
    }

    // MARK: - 本地移除（Owner 移除／作者刪除成功後）

    func test_removeLocally_removesMatchingComment() async {
        let stub = StubCommentAPIClient()
        let keep = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 1), body: "留下")
        let remove = makeRow(id: UUID(), createdAt: Date(timeIntervalSince1970: 2), body: "移除")
        stub.setListCommentsHandler { _, _, _, _, _ in [remove, keep] }
        let store = makeStore(stub)
        await store.loadInitial()

        store.removeLocally(commentID: remove.id)

        XCTAssertEqual(store.comments.map(\.body), ["留下"])
    }
}
