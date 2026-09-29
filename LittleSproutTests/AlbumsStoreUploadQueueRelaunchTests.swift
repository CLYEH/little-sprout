import Foundation
@testable import LittleSprout
import XCTest

/// LS-397 merge-review R1 M2：app 被回收後還原的佇列項，「指定寶貝」標記與相簿掛載都要接得回來——
/// 標記追蹤器的群狀態只存在記憶體，重啟後靠落盤的 `babyIDs` 重新登記成「補交」路徑。
@MainActor
final class AlbumsStoreUploadQueueRelaunchTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func waitUntil(timeoutSeconds: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// 第一個行程：一群指定寶貝的照片入列（登記相簿與追蹤器群），上傳卡住時被回收。第二個行程：全新的
    /// `AlbumsStore`（追蹤器記憶體是空的）從落盤還原，續傳成功後必須對這一筆補送寶貝標記、並掛進相簿。
    func test_relaunch_restoredItemStillCarriesBabyIDs_andGetsMarkedAfterResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ls397-\(UUID().uuidString)")
        directories.append(directory)
        let persistence = UploadQueuePersistence(directory: directory)
        let babyID = UUID()
        let albumID = UUID()
        let entryID = UUID()

        let firstAlbums = AlbumsStore(apiClient: StubAlbumsAPIClient())
        firstAlbums.uploadQueuePersistenceFactory = { _ in persistence }
        let hanging = StubMediaUploadService()
        hanging.setUploadPhotoHandler { _, _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return UUID()
        }
        let firstQueue = firstAlbums.sharedUploadQueueStore(familyID: familyID, mediaUploadService: hanging)
        let groupKey = MediaChildrenMarkingTracker.GroupKey()
        firstAlbums.mediaChildrenMarker.beginGroup(groupKey, babyIDs: [babyID])
        firstAlbums.registerPendingAlbum(entryID: entryID, albumID: albumID)
        firstAlbums.mediaChildrenMarker.registerEntry(groupKey, entryID: entryID)
        firstQueue.enqueue([
            PendingUpload(
                id: entryID, kind: .photo(data: Data("x".utf8), fileExtension: "jpg"), thumbnail: nil,
                pixelSize: PixelSize(width: 4, height: 3)
            )
        ])
        XCTAssertEqual(persistence.loadRecords().first?.babyIDs, [babyID], "入列時寶貝 id 要隨佇列項一起落盤")
        firstQueue.resume.tasks.values.forEach { $0.cancel() } // 行程被回收：飛行中的請求消失

        let secondAPI = StubAlbumsAPIClient()
        let secondAlbums = AlbumsStore(apiClient: secondAPI)
        secondAlbums.uploadQueuePersistenceFactory = { _ in persistence }
        let mediaID = UUID()
        let resumed = StubMediaUploadService()
        resumed.setUploadPhotoHandler { _, _, _, _ in mediaID }
        _ = secondAlbums.sharedUploadQueueStore(familyID: familyID, mediaUploadService: resumed)

        await waitUntil { !secondAPI.setMediaChildrenBatchCalls.isEmpty && !secondAPI.attachMediaCalls.isEmpty }
        XCTAssertEqual(
            secondAPI.setMediaChildrenBatchCalls.map(\.items),
            [[MediaChildrenBatchItem(mediaID: mediaID, childIDs: [babyID])]],
            "重啟續傳成功後要補送寶貝標記（原本的群狀態已在記憶體消失，靠落盤的 babyIDs 重新登記）"
        )
        XCTAssertEqual(secondAPI.attachMediaCalls.map(\.albumID), [albumID], "相簿對照也要還原並掛進去")
    }
}
