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
