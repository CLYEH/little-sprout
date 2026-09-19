import Foundation
@testable import LittleSprout
import XCTest

/// LS-303 R4（merge-review R3 M1／M2，orchestrator 裁決 `8579e30e`）：`AlbumsStore
/// .sharedUploadQueueStore`／`registerPendingAlbum`——「加入照片」單張即傳與批次匯入過渡管線
/// 共用同一份 app 層級 `UploadQueueStore` 的核心機制，拆成獨立檔案同 `AlbumsStoreAttachUploadedMediaTests`
/// 既有拆檔理由。
@MainActor
final class AlbumsStoreSharedUploadQueueTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let familyB = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private func waitUntil(
        timeoutSeconds: Double = 1, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                return XCTFail("等待條件成立逾時", file: file, line: line)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// M1 核心保證：不管呼叫幾次，都是同一個實例——這正是「併發上限回到單一份」的前提
    /// （拆成多份呼叫端各自的 `maxConcurrentUploads` 才會乘以呼叫次數，見 merge-review R3
    /// M1）。
    func test_sharedUploadQueueStore_multipleCalls_returnsSameInstance() {
        let store = AlbumsStore(apiClient: StubAlbumsAPIClient())
        let mediaService = StubMediaUploadService()

        let first = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        let second = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)

        XCTAssertTrue(first === second, "同一個 AlbumsStore 多次呼叫應該拿到同一個 UploadQueueStore 實例")
    }

    /// `registerPendingAlbum` 查表：兩筆不同 entry 各自登記不同 albumID，完成後各自掛進
    /// 正確的相簿——證明單一 store 可以同時服務多個相簿情境而不混淆（同 M1 修法的直接目的）。
    func test_onUploadSucceeded_looksUpRegisteredAlbumID_forEachEntrySeparately() async {
        let apiStub = StubAlbumsAPIClient()
        let store = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let albumA = UUID()
        let albumB = UUID()
        let entryA = UUID()
        let entryB = UUID()

        let queue = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        store.registerPendingAlbum(entryID: entryA, albumID: albumA)
        store.registerPendingAlbum(entryID: entryB, albumID: albumB)
        queue.enqueue([
            PendingUpload(
                id: entryA, kind: .photo(data: Data("a".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            ),
            PendingUpload(
                id: entryB, kind: .photo(data: Data("b".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])

        await waitUntil { apiStub.attachMediaCalls.count == 2 }
        let albumIDs = Set(apiStub.attachMediaCalls.map(\.albumID))
        XCTAssertEqual(albumIDs, [albumA, albumB], "兩筆各自登記的 albumID 都要正確反映在 attachMedia 呼叫上")
    }

    /// M1（LS-303 R5，merge-review R4 `902eb329`）：登出（`reset()`）之後同一個 app 行程內
    /// 換帳號登入，共用佇列必須用新帳號的 `familyID`——不能沿用舊帳號焊在快取實例裡的值
    /// （`AlbumsStore.reset()` 修前只清 `sortOrderCursors`／`detailStoreByAlbumID`，沒清
    /// `sharedUploadQueueStoreInstance`／`pendingUploadAlbumIDs`，見 `AlbumsStore.reset()`
    /// 文件註解）。
    func test_sharedUploadQueueStore_afterReset_usesNewFamilyID() async {
        let apiStub = StubAlbumsAPIClient()
        let store = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()

        _ = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        store.reset()
        let queue = store.sharedUploadQueueStore(familyID: familyB, mediaUploadService: mediaService)
        queue.enqueue([
            PendingUpload(
                kind: .photo(data: Data("x".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])

        await waitUntil { !mediaService.uploadPhotoCalls.isEmpty }
        XCTAssertEqual(
            mediaService.uploadPhotoCalls.first?.familyID, familyB,
            "登出換帳號後，共用佇列應該用新家庭 id 上傳"
        )
    }

    /// M1（LS-303 R5）：`reset()` 之後 `sharedUploadQueueStore` 必須建一個**新的**實例——
    /// 光是 `familyID` 對，若還在用同一個舊實例（例如只改 `reset()` 沒清
    /// `sharedUploadQueueStoreInstance`），代表快取沒真的失效，只是巧合下一次呼叫傳的
    /// `familyID` 沒被用到（`sharedUploadQueueStore` 對已存在的實例會忽略新傳入的
    /// `familyID`，見該函式文件註解）。
    func test_sharedUploadQueueStore_afterReset_returnsNewInstance() {
        let store = AlbumsStore(apiClient: StubAlbumsAPIClient())
        let mediaService = StubMediaUploadService()

        let before = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        store.reset()
        let after = store.sharedUploadQueueStore(familyID: familyB, mediaUploadService: mediaService)

        XCTAssertFalse(before === after, "reset() 後應該重新建立 UploadQueueStore 實例，不沿用舊的")
    }

    /// i1（LS-303 R5，merge-review R4 `902eb329`）：不可重試失敗終局（`.quota`）也要從
    /// `pendingUploadAlbumIDs` 直接移除——不是只有成功才清，見 `UploadQueueStore
    /// .onUploadFailedTerminal` 文件註解。
    func test_onUploadFailedTerminal_removesEntryFromPendingAlbumIDs() async {
        let apiStub = StubAlbumsAPIClient()
        let store = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let albumID = UUID()
        let entryID = UUID()
        mediaService.setUploadPhotoHandler { _, _, _, _ in
            throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
        }

        let queue = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        store.registerPendingAlbum(entryID: entryID, albumID: albumID)
        queue.enqueue([
            PendingUpload(
                id: entryID, kind: .photo(data: Data("x".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])

        await waitUntil { queue.failedCount == 1 }
        XCTAssertNil(store.pendingUploadAlbumIDs[entryID], "終局失敗後對照表項目應該被移除")
    }

    /// LS-328：`onUploadSucceeded` 要通知 `timelineStore`——不管這筆有沒有掛相簿（這裡刻意
    /// **不** `registerPendingAlbum`，驗證跟下面「只有登記過 albumID 才 attachMedia」是不同
    /// 分支，見 `AlbumsStore+SharedUploadQueue.swift` 該掛鉤文件註解）。去抖／dirty 內部邏輯
    /// 見 `TimelineStoreImportRefreshTests.swift`，這裡只驗證 wiring 本身真的接上。
    func test_onUploadSucceeded_notifiesTimelineStore_regardlessOfAlbumRegistration() async {
        let apiStub = StubAlbumsAPIClient()
        let store = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()
        let timelineStub = StubTimelineAPIClient()
        timelineStub.setFetchPointersHandler { _, _, _, _ in [] }
        let timelineStore = TimelineStore(apiClient: timelineStub)
        timelineStore.importRefresh.debounceDelay = {}
        store.timelineStore = timelineStore

        let queue = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        queue.enqueue([
            PendingUpload(
                kind: .photo(data: Data("x".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])

        await waitUntil { timelineStore.importRefresh.debounceToken > 0 }
        XCTAssertGreaterThan(timelineStore.importRefresh.debounceToken, 0, "上傳成功應該通知時間軸，不管有沒有掛相簿")
    }

    /// 沒有登記過的 entry（理論上不該發生，防禦性測試）完成後不該呼叫 `attachMedia`——
    /// `pendingUploadAlbumIDs.removeValue` 找不到就整個 guard 落空。
    func test_onUploadSucceeded_unregisteredEntry_doesNotCallAttachMedia() async {
        let apiStub = StubAlbumsAPIClient()
        let store = AlbumsStore(apiClient: apiStub)
        let mediaService = StubMediaUploadService()

        let queue = store.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        queue.enqueue([
            PendingUpload(
                kind: .photo(data: Data("x".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])

        await waitUntil { queue.remainingCount == 0 }
        XCTAssertTrue(apiStub.attachMediaCalls.isEmpty, "沒登記過相簿的 entry 不該觸發 attachMedia")
    }
}
