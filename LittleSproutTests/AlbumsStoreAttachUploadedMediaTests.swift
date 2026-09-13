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

    /// LS-246（票文範圍 3，池 `430a34a1` n1）：`nextSortOrder` 的 `catch` 原本只看「現在是不是
    /// 還有什麼 `.pending`」就清掉（`if case .pending = ...`），沒有核對是不是「自己剛才在等的
    /// 那一筆」——晚到才處理失敗的等待者，可能把「另一個交錯呼叫端剛建立、還在飛行中」的全新
    /// 查詢誤清成 `nil`，代價是那個呼叫端的重試又白白多打一次查詢（無正確性影響，見
    /// merge-review `5be48b1e` n1；比對 pendingID 修正）。
    ///
    /// 重現手法：三個呼叫端（A 觸發、B／C 兩個等待者）共用第一次查詢並失敗——A 的 catch
    /// 核對 id 相符後清空＋拋錯；B／C 各自的 catch 發現已清空，各自遞迴重試 `nextSortOrder`。
    /// 若沒有 id 比對，B／C 兩邊的遞迴呼叫會互相清掉對方剛建立的第二輪 `.pending`，導致總共
    /// 打了 3 次 `fetchMaxSortOrder`（1 次失敗＋2 次各自獨立的第二輪查詢）；修正後 B／C
    /// 應該正確共用同一個第二輪查詢（single-flight），總共只打 2 次。
    func test_attachUploadedMedia_failedQueryCatch_onlyClearsOwnPendingTask_notNewerOneFromAnotherCaller() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let gate1 = AsyncGate()
        let gate2 = AsyncGate()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMaxSortOrderHandler { _ in
            let index = invocationCount.withLock { count -> Int in
                count += 1
                return count
            }
            if index == 1 {
                await gate1.wait()
                throw AppError.network(message: "offline")
            }
            await gate2.wait()
            return 9
        }
        let store = AlbumsStore(apiClient: stub)
        let mediaA = UUID()
        let mediaB = UUID()
        let mediaC = UUID()

        let taskA = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaA) }
        // 等到觸發查詢的那一次卡在網路 await——program-order 保證 B／C 加入的是同一個
        // in-flight task（同既有 F2 測試寫法）。
        await gate1.waitForWaiters(count: 1)
        let taskB = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaB) }
        let taskC = Task { await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaC) }
        await Task.yield()
        await Task.yield()

        await gate1.open()
        // 至少一次「第二輪」查詢已經卡住——不管 B／C 是否正確共用同一筆（修正後）或各自獨立
        // 觸發（未修正），這裡只需要等到第一個到達，`gate2.open()` 之後 `isOpen` 恆為 true，
        // 晚到的第二個（若有）呼叫 `wait()` 會立即通過，不需要另外處理。
        await gate2.waitForWaiters(count: 1)
        await gate2.open()
        _ = await (taskA.value, taskB.value, taskC.value)

        XCTAssertEqual(
            stub.fetchMaxSortOrderCalls.count, 2,
            "B／C 應該共用同一個第二輪查詢（single-flight）——只清自己那筆 pending，不該互相清掉對方剛建立的查詢"
        )
        let attachedMediaIDs = Set(stub.attachMediaCalls.map(\.mediaID))
        XCTAssertTrue(
            attachedMediaIDs.contains(mediaB) && attachedMediaIDs.contains(mediaC),
            "B／C 的重試都應該成功——一個晚到的失敗處理不該波及另一個交錯呼叫端剛建立的查詢"
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

    /// LS-246（票文範圍 4，池 `430a34a1` n2）：TTL 改以「取得時刻」判過期，不是「使用時刻」
    /// ——見 `AlbumsStore.sortOrderCursorIdleTTL` 文件註解。這支測試的三次呼叫刻意讓「每次
    /// 相鄰使用的間隔」都在 60 秒 TTL 之內（0→40 秒、40→70 秒），但「距離第一次取得基底值」
    /// 累計已經超過 60 秒（70 秒）——若 TTL 是「使用時刻」判過期（每次用到就把時間戳延後），
    /// 這裡會一直沿用第一次查到的基底，永遠不會重新查詢；「取得時刻」判過期則會在累計超過
    /// 60 秒的第三次呼叫時正確重新查詢。
    func test_attachUploadedMedia_cursorTTL_measuredFromAcquisitionTime_notFromEachUse() async {
        let stub = StubAlbumsAPIClient()
        let albumID = UUID()
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setFetchMaxSortOrderHandler { _ in
            invocationCount.withLock { count -> Int in
                count += 1
                // 第一次查到基底 4；第二次（累計超過 TTL 後重新查）代表期間別的裝置加了更多
                // 照片，基底變成 20——不是延續第一次的快取值。
                return count == 1 ? 4 : 20
            }
        }
        var tick: TimeInterval = 0
        let store = AlbumsStore(apiClient: stub, now: { Date(timeIntervalSince1970: tick) })

        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())
        tick += 40 // 距離取得時刻 40 秒，< 60 秒 TTL，沿用快取
        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())
        tick += 30 // 距離上一次使用只有 30 秒，但距離取得時刻已經累計 70 秒，> 60 秒 TTL
        await store.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: UUID())

        XCTAssertEqual(
            stub.fetchMaxSortOrderCalls.count, 2,
            "距離『取得基底值』已經過 70 秒（>60 秒 TTL），即使距離上一次『使用』只有 30 秒，也該視為過期重新查詢"
        )
        XCTAssertEqual(
            stub.attachMediaCalls.map(\.sortOrder), [5, 6, 21],
            "第三次應該重新查到基底 20、接續 21——不是沿用第一次快取（延續下去會是 7）"
        )
    }
}
