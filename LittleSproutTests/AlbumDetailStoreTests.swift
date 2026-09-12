import Foundation
@testable import LittleSprout
import XCTest

/// LS-166：`AlbumDetailStore` 的載入／即時掛照片／編輯流程——同 `AlbumsStoreTests` 的拆檔慣例，
/// 資料層測試全走 `StubAlbumsAPIClient`，不碰真實網路或本機容器。
@MainActor
final class AlbumDetailStoreTests: XCTestCase {
    private let albumID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let familyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// `thumbPath` 預設帶 `id` 讓每一列的路徑都不同——同一批 `fetchMedia` 結果裡若有兩列
    /// `thumb_path` 撞同一個字面值，`signedURLs(forStoragePaths:)` 批次簽名時會把它們當成
    /// 同一個 storage path，`Dictionary(uniqueKeysWithValues:)`（測試 stub 常見寫法）在重複
    /// key 上會直接 crash——真實後端資料不會發生（路徑本身嵌入 `media_id`），這裡用 `id`
    /// 组出獨立路徑，避免測試 fixture 本身湊出一個不會在生產環境發生的假重複。
    private nonisolated static func makeMediaRow(id: UUID, hasThumb: Bool = true) -> MediaRow {
        let thumbPath = hasThumb ? "thumb/\(id).jpg" : nil
        return MediaRow(
            id: id, storagePath: "orig/\(id).jpg", type: .photo, width: 400, height: 300,
            thumbPath: thumbPath, thumbWidth: hasThumb ? 200 : nil, thumbHeight: hasThumb ? 150 : nil,
            durationSeconds: nil
        )
    }

    /// 把每個 storage path 原樣簽成一個假 URL——只用來讓 `AlbumDetailStore` 的
    /// `signedURL` 欄位非 nil，測試不驗證簽名 URL 本身的內容。
    private nonisolated static func echoSignedURLsHandler(_ paths: [String]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
    }

    private func makeStore(apiClient: StubAlbumsAPIClient) -> AlbumDetailStore {
        AlbumDetailStore(albumID: albumID, familyID: familyID, title: "起始標題", childIDs: [], apiClient: apiClient)
    }

    // MARK: - refresh

    func test_refresh_sortsByLinkSortOrderDescending_newestFirst() async {
        let idOld = UUID()
        let idNew = UUID()
        let capturedAlbumID = albumID
        let apiClient = StubAlbumsAPIClient()
        apiClient.setFetchAlbumMediaLinksHandler { _ in
            [
                AlbumMediaLinkRow(albumId: capturedAlbumID, mediaId: idOld, sortOrder: 0),
                AlbumMediaLinkRow(albumId: capturedAlbumID, mediaId: idNew, sortOrder: 1)
            ]
        }
        apiClient.setFetchMediaHandler { ids in ids.map { Self.makeMediaRow(id: $0) } }
        apiClient.setSignedURLsHandler(Self.echoSignedURLsHandler)
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.loadState, .success)
        XCTAssertEqual(store.photos.map(\.id), [idNew, idOld], "sortOrder 較大（較新加入）的排最前")
        XCTAssertEqual(store.photoCount, 2)
    }

    func test_refresh_linkPointsToInvisibleMedia_skipsItWithoutThrowing() async {
        let visibleID = UUID()
        let invisibleID = UUID()
        let capturedAlbumID = albumID
        let apiClient = StubAlbumsAPIClient()
        apiClient.setFetchAlbumMediaLinksHandler { _ in
            [
                AlbumMediaLinkRow(albumId: capturedAlbumID, mediaId: visibleID, sortOrder: 0),
                AlbumMediaLinkRow(albumId: capturedAlbumID, mediaId: invisibleID, sortOrder: 1)
            ]
        }
        // RLS 濾掉看不見的那筆——`fetchMedia` 只回傳看得到的那筆，同 LS-165 `AlbumListingRow`
        // 「兩者皆無才 nil」的既有防線理由。
        apiClient.setFetchMediaHandler { ids in ids.filter { $0 == visibleID }.map { Self.makeMediaRow(id: $0) } }
        apiClient.setSignedURLsHandler(Self.echoSignedURLsHandler)
        let store = makeStore(apiClient: apiClient)

        await store.refresh()

        XCTAssertEqual(store.photos.map(\.id), [visibleID], "看不到的那張連結列被安靜跳過，不 throw")
    }

    func test_refresh_failure_setsFailureState() async {
        let apiClient = StubAlbumsAPIClient()
        apiClient.setFetchAlbumMediaLinksHandler { _ in throw AppError.network(message: "offline") }
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.refresh()

        XCTAssertFalse(succeeded)
        guard case .failure = store.loadState else { return XCTFail("預期 failure 狀態") }
    }

    func test_refresh_emptyAlbum_producesEmptyPhotosAndSuccess() async {
        let apiClient = StubAlbumsAPIClient()
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(store.photos.isEmpty)
        XCTAssertEqual(store.loadState, .success)
    }

    // MARK: - reflectUploadedMedia（merge-review R2 M2：UI-only，寫入已移到 AlbumsStore）

    /// merge-review R2 M2：這支方法**不再**打 `attachMedia`——`album_media` 的寫入已經移到
    /// `AlbumsStore.attachUploadedMedia`（見該方法與 `AlbumsStoreTests` 的對應測試），這裡只
    /// 驗證「media 抓得到就插進畫面」這一半。
    func test_reflectUploadedMedia_prependsToPhotos_whenMediaFetchSucceeds() async {
        let apiClient = StubAlbumsAPIClient()
        apiClient.setFetchMediaHandler { ids in ids.map { Self.makeMediaRow(id: $0) } }
        apiClient.setSignedURLsHandler(Self.echoSignedURLsHandler)
        let store = makeStore(apiClient: apiClient)
        let existingID = UUID()
        store.seedForPreview(photos: [
            MediaContent(
                id: existingID, type: .photo, width: 400, height: 300, thumbWidth: 200, thumbHeight: 150,
                storagePath: "orig/existing.jpg", isThumbnail: true,
                signedURL: URL(string: "https://example.com/existing"), durationSeconds: nil
            )
        ])
        let newMediaID = UUID()

        await store.reflectUploadedMedia(newMediaID)

        XCTAssertTrue(apiClient.attachMediaCalls.isEmpty, "寫入已經移到 AlbumsStore，這支方法不該再打一次 attachMedia")
        XCTAssertEqual(store.photos.map(\.id), [newMediaID, existingID], "新加入的照片插在最前面")
    }

    /// `fetchMedia` 抓不到這筆（例如已經被別的流程軟刪，或掛鉤的 mediaID 有誤）時不拋錯、
    /// 也不插入——同舊版 `attachUploadedMedia` 對 INSERT 失敗的 best-effort 取捨（見
    /// 該方法舊文件註解，現移到 `AlbumsStore.attachUploadedMedia`），這裡是 UI-only 那一半
    /// 的對應情境。
    func test_reflectUploadedMedia_fetchMediaReturnsEmpty_doesNotThrow_andDoesNotAppendPhoto() async {
        let apiClient = StubAlbumsAPIClient()
        apiClient.setFetchMediaHandler { _ in [] }
        let store = makeStore(apiClient: apiClient)

        await store.reflectUploadedMedia(UUID())

        XCTAssertTrue(store.photos.isEmpty, "抓不到這筆 media 的話不該出現在照片牆")
    }

    func test_reflectUploadedMedia_alreadyPresent_doesNotDuplicate() async {
        let apiClient = StubAlbumsAPIClient()
        let mediaID = UUID()
        apiClient.setFetchMediaHandler { ids in ids.map { Self.makeMediaRow(id: $0) } }
        apiClient.setSignedURLsHandler { _ in [:] }
        let store = makeStore(apiClient: apiClient)
        store.seedForPreview(photos: [
            MediaContent(
                id: mediaID, type: .photo, width: 400, height: 300, thumbWidth: nil, thumbHeight: nil,
                storagePath: "orig/dup.jpg", isThumbnail: false, signedURL: nil, durationSeconds: nil
            )
        ])

        await store.reflectUploadedMedia(mediaID)

        XCTAssertEqual(store.photos.count, 1, "同一個 id 已經在畫面上就不重複插入")
    }

    // MARK: - submitEdit

    func test_submitEdit_titleChangedOnly_callsUpdateTitle_notSetAlbumChildren() async {
        let apiClient = StubAlbumsAPIClient()
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.submitEdit(title: "新標題", childIDs: [])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(apiClient.updateAlbumTitleCalls.map(\.title), ["新標題"])
        XCTAssertTrue(apiClient.setAlbumChildrenCalls.isEmpty, "childIDs 沒變不該多打一次請求")
        XCTAssertEqual(store.title, "新標題")
        XCTAssertEqual(store.editState, .success)
    }

    func test_submitEdit_childIDsChangedOnly_callsSetAlbumChildren_notUpdateTitle() async {
        let apiClient = StubAlbumsAPIClient()
        let store = makeStore(apiClient: apiClient)
        let childID = UUID()

        let succeeded = await store.submitEdit(title: "起始標題", childIDs: [childID])

        XCTAssertTrue(succeeded)
        XCTAssertTrue(apiClient.updateAlbumTitleCalls.isEmpty, "title 沒變不該多打一次請求")
        XCTAssertEqual(apiClient.setAlbumChildrenCalls.map(\.childIDs), [[childID]])
        XCTAssertEqual(store.childIDs, [childID])
    }

    func test_submitEdit_titleUpdateFails_reportsFailure_doesNotCallSetAlbumChildren() async {
        let apiClient = StubAlbumsAPIClient()
        apiClient.setUpdateAlbumTitleHandler { _, _ in throw AppError.rejected(message: "不是建立者", code: "42501") }
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.submitEdit(title: "新標題", childIDs: [UUID()])

        XCTAssertFalse(succeeded)
        guard case .failure = store.editState else { return XCTFail("預期 failure 狀態") }
        XCTAssertTrue(apiClient.setAlbumChildrenCalls.isEmpty, "title 失敗就不該繼續打 setAlbumChildren")
        XCTAssertEqual(store.title, "起始標題", "失敗不該更新本地 title")
    }

    func test_submitEdit_neitherChanged_isNoOp_stillReportsSuccess() async {
        let apiClient = StubAlbumsAPIClient()
        let store = makeStore(apiClient: apiClient)

        let succeeded = await store.submitEdit(title: "起始標題", childIDs: [])

        XCTAssertTrue(succeeded)
        XCTAssertTrue(apiClient.updateAlbumTitleCalls.isEmpty)
        XCTAssertTrue(apiClient.setAlbumChildrenCalls.isEmpty)
    }
}
