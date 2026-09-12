import Foundation
@testable import LittleSprout
import os
import XCTest

/// `AlbumsStore.attachUploadedMedia`（merge-review R2 M2；LS-237 修，池 `4fafaa19`(a)(b)）
/// ——抽成獨立檔案（同 `AlbumsStoreTests` 拆分理由：加進同一個類別會讓那支測試檔逼近
/// SwiftLint `file_length`／`type_body_length` 上限）。
@MainActor
final class AlbumsStoreAttachUploadedMediaTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// merge-review R2 M2 根因重現：使用者在上傳飛行中離開相簿詳情頁，`AlbumDetailView` 的
    /// `@State AlbumDetailStore` 會 deinit，若 `album_media` 寫入掛在那支 store 上，這裡就
    /// 什麼都不會發生。這支測試**完全不建立任何 `AlbumDetailStore` 實例**——直接對長生命週期
    /// 的 `AlbumsStore` 呼叫，模擬「detailStore 早就不存在」的極端情況，證明寫入路徑不依賴它。
    func test_attachUploadedMedia_writesAlbumMedia_withoutAnyAlbumDetailStoreInstance() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let familyID = UUID()
        let mediaID = UUID()
        let store = AlbumsStore(apiClient: stub)

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaID)

        XCTAssertEqual(stub.attachMediaCalls.count, 1, "沒有任何 AlbumDetailStore 存在也該寫入 album_media")
        XCTAssertEqual(stub.attachMediaCalls.first?.albumID, albumID)
        XCTAssertEqual(stub.attachMediaCalls.first?.familyID, familyID)
        XCTAssertEqual(stub.attachMediaCalls.first?.mediaID, mediaID)
    }

    /// LS-237 修（池 `4fafaa19`(a)）：`sortOrder` 改成單次 `fetchMaxSortOrder` 查詢＋本地
    /// 遞增，不再是 `fetchAlbumMediaLinks(albumID:).count`。
    func test_attachUploadedMedia_computesSortOrderFromMaxSortOrder() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        stub.setFetchMaxSortOrderHandler { _ in 4 }
        let store = AlbumsStore(apiClient: stub)

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())

        XCTAssertEqual(stub.attachMediaCalls.first?.sortOrder, 5, "已知最大值 4，新的一筆接續在後")
    }

    /// 沒有任何連結列時 `fetchMaxSortOrder` 回 `nil`（同 `fetchAlbumMediaLinks` 回空陣列的
    /// 情境）——第一張照片的 `sortOrder` 應該是 0。
    func test_attachUploadedMedia_noExistingLinks_startsAtZero() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        stub.setFetchMaxSortOrderHandler { _ in nil }
        let store = AlbumsStore(apiClient: stub)

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())

        XCTAssertEqual(stub.attachMediaCalls.first?.sortOrder, 0, "相簿還沒有任何連結列時第一張應該是 0")
    }

    /// LS-237 驗收「三張並發同批上傳 sortOrder 遞增」：`maxConcurrentUploads = 3` 同批完成的
    /// 三張照片幾乎同時呼叫 `attachUploadedMedia`——舊版現查現算會讓三張都讀到同一個連結數、
    /// 整批同號。用 `AsyncGate` 卡住 `fetchMaxSortOrder` 唯一一次查詢，逼三個呼叫都必須在
    /// 「還不知道基底值」的窗口內做決定，驗證：(1) single-flight——同批只真正打一次
    /// `fetchMaxSortOrder`；(2) 三筆各自拿到不同、從基底值依序遞增的 `sortOrder`，不是整批
    /// 同號、也不是退化成 `mediaId` 字典序。
    func test_attachUploadedMedia_concurrentBatch_assignsDistinctIncrementingSortOrders() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let gate = AsyncGate()
        stub.setFetchMaxSortOrderHandler { _ in
            await gate.wait()
            return 1
        }
        let store = AlbumsStore(apiClient: stub)

        let firstTask = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID()) }
        // 等到第一次呼叫真的卡在 `fetchMaxSortOrder`（single-flight 的唯一一次查詢）——
        // program-order 保證這代表 `.pending` 狀態已經寫進去，才發後續兩次。
        await gate.waitForWaiters(count: 1)
        let secondTask = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID()) }
        let thirdTask = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID()) }
        // 讓第二、三次有機會真的執行到「發現 .pending、加入同一個 in-flight task」那段同步
        // 程式碼——它們加入的是既有 task，不會再呼叫一次 `gate.wait()`，沒有對應的
        // `waitForWaiters` 訊號可等；即使這裡沒有讓出足夠次數、它們在 `gate.open()` 之後才
        // 真正執行，`.ready` 狀態下的同步遞增分支一樣正確，斷言不受影響（見本方法文件註解）。
        await Task.yield()
        await Task.yield()
        await gate.open()
        _ = await (firstTask.value, secondTask.value, thirdTask.value)

        XCTAssertEqual(stub.fetchMaxSortOrderCalls.count, 1, "同批交錯完成只應該打一次 fetchMaxSortOrder（single-flight）")
        let sortOrders = stub.attachMediaCalls.map(\.sortOrder).sorted()
        XCTAssertEqual(sortOrders, [2, 3, 4], "三筆應該各自拿到不同、從基底值 1 依序遞增的 sortOrder，不是整批同號")
    }

    func test_attachUploadedMedia_attachFails_doesNotThrow() async {
        let stub = StubAlbumsAPIClient()
        stub.setAttachMediaHandler { _, _, _, _ in throw AppError.rejected(message: "家庭已停權", code: "LS053") }
        let store = AlbumsStore(apiClient: stub)

        // best-effort：不拋錯（見文件註解），呼叫端（`UploadQueueStore` 的 Task）不需要
        // 額外的 catch 分支。
        await store.attachUploadedMedia(albumID: UUID(), familyID: familyID, mediaID: UUID())
    }

    /// LS-237 修（池 `4fafaa19`(b)）驗收「離開再進看到後續完成的照片」：`subscribeDetailStore`
    /// 登記的是「目前是誰在看這本相簿」，不是呼叫端建立 upload queue 當下捕捉到的那一份——
    /// 模擬「上傳飛行中離開再進同一本相簿」：`staleDetailStore` 先登記（舊畫面），
    /// `freshDetailStore` 後登記（重新進入後的新畫面）取代它，`attachUploadedMedia` 應該只
    /// 通知目前登記者。
    func test_attachUploadedMedia_notifiesCurrentlySubscribedDetailStore_notStaleOne() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let mediaID = UUID()
        let mediaRow = MediaRow(
            id: mediaID, storagePath: "f/photo.jpg", type: .photo, width: 4, height: 3,
            thumbPath: nil, thumbWidth: nil, thumbHeight: nil, durationSeconds: nil
        )
        stub.setFetchMediaHandler { ids in ids.contains(mediaID) ? [mediaRow] : [] }
        let store = AlbumsStore(apiClient: stub)
        let staleDetailStore = AlbumDetailStore(
            albumID: albumID, familyID: familyID, title: "舊", childIDs: [], apiClient: stub
        )
        let freshDetailStore = AlbumDetailStore(
            albumID: albumID, familyID: familyID, title: "新", childIDs: [], apiClient: stub
        )
        store.subscribeDetailStore(albumID: albumID, staleDetailStore)
        store.subscribeDetailStore(albumID: albumID, freshDetailStore)

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaID)

        XCTAssertTrue(
            freshDetailStore.photos.contains(where: { $0.id == mediaID }),
            "目前登記的 detailStore（模擬重新進入後的新畫面）應該立即反映剛上傳完成的照片"
        )
        XCTAssertTrue(staleDetailStore.photos.isEmpty, "已經被新訂閱取代的舊 detailStore 不應該收到通知")
    }

    // MARK: - nextSortOrder single-flight 失敗隔離（LS-237 R2，merge-review R1 F2 minor）

    /// 池 `4fafaa19`(a) 的 single-flight 查詢失敗時，原本共用同一個 `Task` 的所有呼叫端都會
    /// 收到同一個錯誤而放棄——`attachUploadedMedia` 的 catch 是靜默 best-effort，一次暫時性
    /// 網路失敗會讓同批最多 3 張照片全部跳過 `attachMedia`（media 列建好卻沒有連結）。修正後
    /// 只有真正發起查詢那一次（觸發者）失敗，其他加入同一個查詢的呼叫端各自獨立重試一次。
    func test_attachUploadedMedia_sharedSortOrderQueryFails_onlyTriggeringCallFails_othersSucceedIndependently() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let gate = AsyncGate()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMaxSortOrderHandler { _ in
            let isFirst = invocationCount.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if isFirst {
                await gate.wait()
                throw AppError.network(message: "offline")
            }
            return 1
        }
        let store = AlbumsStore(apiClient: stub)
        let triggeringMediaID = UUID()
        let secondMediaID = UUID()
        let thirdMediaID = UUID()

        let firstTask = Task {
            await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: triggeringMediaID)
        }
        // 等到真正發起查詢的那一次卡在網路 await——program-order 保證這代表它已經把
        // `.pending` 狀態寫進去，後續兩次一定會加入同一個 in-flight task。
        await gate.waitForWaiters(count: 1)
        let secondTask = Task {
            await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: secondMediaID)
        }
        let thirdTask = Task {
            await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: thirdMediaID)
        }
        await Task.yield()
        await Task.yield()
        await gate.open()
        _ = await (firstTask.value, secondTask.value, thirdTask.value)

        let attachedMediaIDs = Set(stub.attachMediaCalls.map(\.mediaID))
        XCTAssertFalse(
            attachedMediaIDs.contains(triggeringMediaID),
            "觸發查詢失敗的那一張本來就該失敗（best-effort，media 列建好但不連結）"
        )
        XCTAssertTrue(
            attachedMediaIDs.contains(secondMediaID) && attachedMediaIDs.contains(thirdMediaID),
            "其他兩張不該因為觸發查詢那次失敗而連坐——應該各自獨立重試成功"
        )
    }

    // MARK: - sortOrder cursor TTL（LS-237 R2，merge-review R1 F3 minor）

    /// 池 `4fafaa19`(a) 的 `.ready` cursor 原本整個 app session 不失效——同一個 session 若
    /// 橫跨數小時、期間別的裝置也對同一本相簿加了照片，這裡快取的基底沒有機會發現，下一次
    /// 同步遞增算出的值可能跟別的裝置撞號。修正後閒置超過 TTL（60 秒）就視為這批上傳已經
    /// 結束，下一次呼叫改重新查一次。
    func test_attachUploadedMedia_cursorIdleBeyondTTL_requeriesInsteadOfReusingStaleBase() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMaxSortOrderHandler { _ in
            invocationCount.withLock { count -> Int? in
                count += 1
                // 第一次查到基底 4；第二次（TTL 過期後重新查）代表期間別的裝置加了更多照片，
                // 基底變成 10——不是延續第一次的快取值。
                return count == 1 ? 4 : 10
            }
        }
        var tick: TimeInterval = 0
        let store = AlbumsStore(apiClient: stub, now: { Date(timeIntervalSince1970: tick) })

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())
        XCTAssertEqual(stub.attachMediaCalls.first?.sortOrder, 5, "第一次：查到基底 4，接續 5")

        tick += 61 // 超過 60 秒 TTL
        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())

        XCTAssertEqual(stub.fetchMaxSortOrderCalls.count, 2, "閒置超過 TTL 應該重新查一次，不是沿用舊快取")
        XCTAssertEqual(
            stub.attachMediaCalls.last?.sortOrder, 11,
            "重新查到基底 10，接續 11——不是沿用第一次快取（6）"
        )
    }

    /// 對稱情境：TTL 之內連續使用（同一批次接續上傳）不該重新查詢，維持既有 single-flight
    /// 行為——避免這支修法在正常情況下反而讓每張照片都多打一次查詢。
    func test_attachUploadedMedia_cursorUsedWithinTTL_doesNotRequery() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        stub.setFetchMaxSortOrderHandler { _ in 4 }
        var tick: TimeInterval = 0
        let store = AlbumsStore(apiClient: stub, now: { Date(timeIntervalSince1970: tick) })

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())
        tick += 30 // 30 秒 < 60 秒 TTL
        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())

        XCTAssertEqual(stub.fetchMaxSortOrderCalls.count, 1, "TTL 之內應該沿用快取，不重新查詢")
        XCTAssertEqual(stub.attachMediaCalls.map(\.sortOrder), [5, 6])
    }
}
