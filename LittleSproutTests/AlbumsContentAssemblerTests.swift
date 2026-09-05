import Foundation
@testable import LittleSprout
import XCTest

/// `AlbumsContentAssembler`——組裝張數（`album_media` 分組計數）、封面（`cover_media_id` 指到
/// 的 media 列＋簽名 URL）、寶貝標記 id（`album_children` 分組）。
final class AlbumsContentAssemblerTests: XCTestCase {
    func test_emptyRows_returnsEmptyWithoutCallingAPIClient() async throws {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumMediaLinksHandler { _ in
            XCTFail("空陣列不應該發請求")
            return []
        }

        let result = try await AlbumsContentAssembler.assemble(rows: [], apiClient: stub)

        XCTAssertTrue(result.isEmpty)
    }

    func test_photoCount_groupedByAlbumID() async throws {
        let albumA = UUID()
        let albumB = UUID()
        let rows = [
            AlbumListingRow(id: albumA, title: "相簿 A", coverMediaId: nil, createdAt: Date()),
            AlbumListingRow(id: albumB, title: "相簿 B", coverMediaId: nil, createdAt: Date())
        ]
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumMediaLinksHandler { _ in
            [
                AlbumMediaLinkRow(albumId: albumA, mediaId: UUID()),
                AlbumMediaLinkRow(albumId: albumA, mediaId: UUID()),
                AlbumMediaLinkRow(albumId: albumA, mediaId: UUID()),
                AlbumMediaLinkRow(albumId: albumB, mediaId: UUID())
            ]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first { $0.id == albumA }?.photoCount, 3)
        XCTAssertEqual(result.first { $0.id == albumB }?.photoCount, 1)
    }

    func test_albumWithNoMediaLinks_hasZeroPhotoCount() async throws {
        let albumID = UUID()
        let rows = [AlbumListingRow(id: albumID, title: "空相簿", coverMediaId: nil, createdAt: Date())]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.photoCount, 0)
    }

    func test_childIds_groupedByAlbumID() async throws {
        let albumID = UUID()
        let childA = UUID()
        let childB = UUID()
        let rows = [AlbumListingRow(id: albumID, title: "相簿", coverMediaId: nil, createdAt: Date())]
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumChildrenHandler { _ in
            [
                AlbumChildLinkRow(albumId: albumID, childId: childA),
                AlbumChildLinkRow(albumId: albumID, childId: childB)
            ]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(Set(result.first?.childIds ?? []), Set([childA, childB]))
    }

    func test_coverMediaId_present_resolvesSignedCoverUsingThumbPathPriority() async throws {
        let albumID = UUID()
        let coverMediaID = UUID()
        let rows = [
            AlbumListingRow(id: albumID, title: "相簿", coverMediaId: coverMediaID, createdAt: Date())
        ]
        let stub = StubAlbumsAPIClient()
        stub.setFetchMediaHandler { ids in
            XCTAssertEqual(ids, [coverMediaID])
            return [
                MediaRow(
                    id: coverMediaID, storagePath: "f/full.jpg", type: .photo, width: 1200, height: 900,
                    thumbPath: "f/thumb.jpg", thumbWidth: 300, thumbHeight: 225, durationSeconds: nil
                )
            ]
        }
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/thumb.jpg"], "應該簽縮圖路徑，不是原圖")
            return ["f/thumb.jpg": URL(string: "https://example.com/signed-thumb.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        let cover = try XCTUnwrap(result.first?.cover)
        XCTAssertEqual(cover.signedURL, URL(string: "https://example.com/signed-thumb.jpg"))
        XCTAssertTrue(cover.isThumbnail)
    }

    /// LS-165 未實作「cover_media_id 為 null 時取 album_media 最新一筆」的 fallback（見
    /// `AlbumsContentAssembler.displayPath` 文件註解與 handoff「未完成」欄）——這裡釘住目前
    /// 刻意選擇的行為：未指定封面時 `cover` 為 `nil`，不是自動退回任何一張已連結的照片。
    func test_coverMediaId_nil_resultsInNilCover_noFallbackToAlbumMedia() async throws {
        let albumID = UUID()
        let rows = [AlbumListingRow(id: albumID, title: "相簿", coverMediaId: nil, createdAt: Date())]
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumMediaLinksHandler { _ in [AlbumMediaLinkRow(albumId: albumID, mediaId: UUID())] }
        stub.setFetchMediaHandler { ids in
            XCTFail("未指定封面時不應該查任何 media 列，收到 ids=\(ids)")
            return []
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertNil(result.first?.cover)
    }

    func test_resultOrder_matchesInputRowsOrder() async throws {
        let first = UUID()
        let second = UUID()
        let rows = [
            AlbumListingRow(id: first, title: "第一", coverMediaId: nil, createdAt: Date()),
            AlbumListingRow(id: second, title: "第二", coverMediaId: nil, createdAt: Date().addingTimeInterval(-1))
        ]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.map(\.id), [first, second])
    }
}
