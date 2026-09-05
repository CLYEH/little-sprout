import Foundation
@testable import LittleSprout
import XCTest

private func albumRow(id: UUID = UUID(), title: String = "相簿", createdAt: Date) -> AlbumListingRow {
    AlbumListingRow(id: id, title: title, coverMediaId: nil, createdAt: createdAt)
}

/// 同 `TimelineStoreTests.AsyncGate`（`private`，以檔案為界，這裡另建一份小型版本）——精準
/// 控制併發測試裡「誰先完成」，不用 `Task.sleep` 猜時間。
private actor AlbumsTestAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class AlbumsStoreTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: - refresh

    func test_refresh_success_populatesAlbumsAndHasMorePages() async {
        let stub = StubAlbumsAPIClient()
        let rows = (0..<AlbumsStore.pageSize).map { index in
            albumRow(createdAt: Date().addingTimeInterval(TimeInterval(-index)))
        }
        stub.setFetchAlbumsHandler { _, _, _ in rows }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.refresh(familyID: familyID)

        XCTAssertTrue(success)
        XCTAssertEqual(store.albums.count, AlbumsStore.pageSize)
        // 滿一頁（等於 pageSize）＝可能還有下一頁——同 TimelineStore 的既有判準。
        XCTAssertTrue(store.hasMorePages)
        XCTAssertEqual(store.refreshState, .success)
    }

    func test_refresh_partialPage_setsHasMorePagesFalse() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [albumRow(createdAt: Date())] }
        let store = AlbumsStore(apiClient: stub)

        await store.refresh(familyID: familyID)

        XCTAssertFalse(store.hasMorePages)
    }

    func test_refresh_failure_setsFailureState() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.refresh(familyID: familyID)

        XCTAssertFalse(success)
        guard case .failure = store.refreshState else {
            return XCTFail("預期 refreshState 為 .failure，實際是 \(store.refreshState)")
        }
    }

    func test_refresh_firstPage_omitsCursor() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let store = AlbumsStore(apiClient: stub)

        await store.refresh(familyID: familyID)

        XCTAssertNil(stub.fetchAlbumsCalls.last?.cursor, "第一頁不應帶游標")
    }

    // MARK: - loadMore

    func test_loadMore_usesLastAlbumAsCursor_andAppends() async {
        let stub = StubAlbumsAPIClient()
        let lastOfFirstPageID = UUID()
        let lastOfFirstPageDate = Date().addingTimeInterval(-100)
        let firstPage = (0..<(AlbumsStore.pageSize - 1)).map { index in
            albumRow(createdAt: lastOfFirstPageDate.addingTimeInterval(TimeInterval(index + 1)))
        } + [albumRow(id: lastOfFirstPageID, createdAt: lastOfFirstPageDate)]
        stub.setFetchAlbumsHandler { _, cursor, _ in cursor == nil ? firstPage : [] }
        let store = AlbumsStore(apiClient: stub)
        await store.refresh(familyID: familyID)
        XCTAssertEqual(store.albums.count, AlbumsStore.pageSize)
        XCTAssertTrue(store.hasMorePages)

        let secondPageID = UUID()
        stub.setFetchAlbumsHandler { _, cursor, _ in
            guard let cursor else { return [] }
            XCTAssertEqual(cursor.id, lastOfFirstPageID)
            XCTAssertEqual(
                cursor.createdAt.timeIntervalSince1970, lastOfFirstPageDate.timeIntervalSince1970, accuracy: 0.001
            )
            return [albumRow(id: secondPageID, createdAt: lastOfFirstPageDate.addingTimeInterval(-1))]
        }

        let success = await store.loadMore()

        XCTAssertTrue(success)
        XCTAssertEqual(store.albums.count, AlbumsStore.pageSize + 1)
        XCTAssertEqual(store.albums.last?.id, secondPageID)
        XCTAssertFalse(store.hasMorePages, "第二頁未滿頁應視為已到底")
    }

    func test_loadMore_whenNoMorePages_doesNothing() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [albumRow(createdAt: Date())] }
        let store = AlbumsStore(apiClient: stub)
        await store.refresh(familyID: familyID)
        XCTAssertFalse(store.hasMorePages)

        let success = await store.loadMore()

        XCTAssertFalse(success)
        XCTAssertEqual(store.albums.count, 1)
    }

    // MARK: - createAlbum

    func test_createAlbum_success_withoutChildren_doesNotCallSetAlbumChildren() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [])

        XCTAssertTrue(success)
        XCTAssertEqual(store.createAlbumState, .success)
        XCTAssertTrue(stub.setAlbumChildrenCalls.isEmpty, "空陣列不應該呼叫 set_album_children")
    }

    func test_createAlbum_success_withChildren_callsSetAlbumChildrenWithCreatedAlbumID() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let createdAlbumID = UUID()
        stub.setCreateAlbumHandler { _, title in
            AlbumListingRow(id: createdAlbumID, title: title, coverMediaId: nil, createdAt: Date())
        }
        let store = AlbumsStore(apiClient: stub)
        let childID = UUID()

        let success = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [childID])

        XCTAssertTrue(success)
        XCTAssertEqual(stub.setAlbumChildrenCalls.last?.albumID, createdAlbumID)
        XCTAssertEqual(stub.setAlbumChildrenCalls.last?.childIDs, [childID])
    }

    func test_createAlbum_refreshesListAfterSuccess() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let store = AlbumsStore(apiClient: stub)

        _ = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [])

        // `fetchAlbumsCalls` 是 `StubAlbumsAPIClient` 自己用鎖保護的紀錄（見該檔），不是這裡
        // 另外捕捉一個可變區域變數——Swift 6 嚴格併發下 `@Sendable` handler 閉包裡直接修改
        // 區域 `var` 會被判定為資料競爭，這裡改讀 stub 本來就有的、執行緒安全的呼叫記錄。
        XCTAssertEqual(stub.fetchAlbumsCalls.count, 1, "建立成功後應該重新整理第一頁，讓新相簿立即出現")
    }

    func test_createAlbum_failure_setsFailureState_andDoesNotRefresh() async {
        let stub = StubAlbumsAPIClient()
        stub.setCreateAlbumHandler { _, _ in throw AppError.validationRetryable(message: "無效", code: "23514") }
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [])

        XCTAssertFalse(success)
        guard case .failure = store.createAlbumState else {
            return XCTFail("預期 createAlbumState 為 .failure，實際是 \(store.createAlbumState)")
        }
        XCTAssertEqual(stub.fetchAlbumsCalls.count, 0, "建立失敗不應該重新整理列表")
    }

    /// merge-review R1 M2：`setAlbumChildren` 失敗時要補償軟刪剛建立的相簿（不留孤兒），
    /// 回報的是原始的「設定寶貝標記」錯誤，且不重新整理列表（新相簿已被軟刪，不該出現）。
    func test_createAlbum_setAlbumChildrenFails_compensatesWithSoftDeleteAndDoesNotRefresh() async {
        let stub = StubAlbumsAPIClient()
        let createdAlbumID = UUID()
        stub.setCreateAlbumHandler { _, title in
            AlbumListingRow(id: createdAlbumID, title: title, coverMediaId: nil, createdAt: Date())
        }
        stub.setSetAlbumChildrenHandler { _, _ in throw AppError.network(message: "offline") }
        stub.setFetchAlbumsHandler { _, _, _ in
            XCTFail("補償軟刪之後不應該重新整理列表")
            return []
        }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [UUID()])

        XCTAssertFalse(success)
        XCTAssertEqual(stub.setAlbumDeletedCalls.last?.albumID, createdAlbumID, "應該補償軟刪剛建立的相簿")
        XCTAssertEqual(stub.setAlbumDeletedCalls.last?.deleted, true)
        guard case .failure = store.createAlbumState else {
            return XCTFail("預期 createAlbumState 為 .failure，實際是 \(store.createAlbumState)")
        }
    }

    /// 補償動作本身失敗（例如網路又斷一次）不該蓋掉原始錯誤——`setAlbumDeleted` 用 `try?`
    /// 吞掉，使用者看到的仍是「設定寶貝標記」失敗的訊息，不是補償失敗的訊息。
    func test_createAlbum_compensationItselfFails_stillReportsOriginalError() async {
        let stub = StubAlbumsAPIClient()
        stub.setSetAlbumChildrenHandler { _, _ in throw AppError.network(message: "設定寶貝標記失敗") }
        stub.setSetAlbumDeletedHandler { _, _ in throw AppError.server(message: "補償也失敗", code: nil) }
        let store = AlbumsStore(apiClient: stub)

        let success = await store.createAlbum(familyID: familyID, title: "新相簿", childIDs: [UUID()])

        XCTAssertFalse(success)
        guard case .failure(let error) = store.createAlbumState else {
            return XCTFail("預期 createAlbumState 為 .failure，實際是 \(store.createAlbumState)")
        }
        guard case .network(let message) = error else {
            return XCTFail("應該回報原始的設定寶貝標記錯誤，實際是 \(error)")
        }
        XCTAssertEqual(message, "設定寶貝標記失敗")
    }

    /// merge-review R1 m2：`createAlbumState` 世代守門——較舊的一次呼叫較晚完成時，不能覆蓋
    /// 較新一次呼叫已經寫回的結果（同 `TimelineStore.generation` 的既有理由）。用
    /// `AsyncGate`（同 `TimelineStoreTests` 既有手法，這裡另建一份小型版本——`private actor`
    /// 以檔案為界，跨檔案用不到那份）精準控制「誰先完成」，不用 `Task.sleep` 猜時間。
    func test_createAlbum_staleCallDoesNotOverwriteNewerCreateAlbumState() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [] }
        let store = AlbumsStore(apiClient: stub)

        let staleGate = AlbumsTestAsyncGate()
        let staleAlbumID = UUID()
        stub.setCreateAlbumHandler { _, title in
            await staleGate.wait()
            return AlbumListingRow(id: staleAlbumID, title: title, coverMediaId: nil, createdAt: Date())
        }

        // 較舊的一次先開始（世代號先遞增），卡在閘門裡——`childIDs` 空陣列，放行後會直接走到
        // `.success` 分支，藉此驗證「就算較舊一次最終『成功』，也不能蓋掉較新一次已經寫回的
        // `.failure`」。
        let staleTask = Task { await store.createAlbum(familyID: familyID, title: "舊的", childIDs: []) }
        while store.createAlbumState != .submitting { await Task.yield() }

        // 較新的一次完整跑完（不卡閘門）：`setAlbumChildren` 失敗，補償軟刪後回報錯誤。
        stub.setCreateAlbumHandler { _, title in
            AlbumListingRow(id: UUID(), title: title, coverMediaId: nil, createdAt: Date())
        }
        stub.setSetAlbumChildrenHandler { _, _ in throw AppError.network(message: "新的失敗") }
        let newResult = await store.createAlbum(familyID: familyID, title: "新的", childIDs: [UUID()])
        XCTAssertFalse(newResult)

        // 放行較舊的一次，讓它完成——它的世代號已經落後，寫回前的 guard 應該讓它靜默作廢。
        await staleGate.open()
        _ = await staleTask.value

        guard case .failure(let error) = store.createAlbumState else {
            return XCTFail("較新一次的失敗結果應該留著，實際是 \(store.createAlbumState)")
        }
        guard case .network(let message) = error else {
            return XCTFail("應該是較新一次呼叫的錯誤，實際是 \(error)")
        }
        XCTAssertEqual(message, "新的失敗", "較舊一次呼叫晚完成時不該覆蓋較新一次已經寫回的 createAlbumState")
    }

    // MARK: - reset

    func test_reset_clearsAlbumsAndState() async {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumsHandler { _, _, _ in [albumRow(createdAt: Date())] }
        let store = AlbumsStore(apiClient: stub)
        await store.refresh(familyID: familyID)
        XCTAssertFalse(store.albums.isEmpty)

        store.reset()

        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertEqual(store.refreshState, .idle)
        XCTAssertTrue(store.hasMorePages)
    }
}
