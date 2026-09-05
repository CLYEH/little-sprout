import Foundation
@testable import LittleSprout
import XCTest

/// `AlbumsContentAssembler`——merge-review R1 M1 之後只剩兩件事：張數原樣轉發（PostgREST
/// aggregate 已經算好，見 `AlbumListingRow` 文件註解）、封面 fallback（M3：`cover_media_id`
/// 優先，否則退回內嵌的最新一筆 album_media）、寶貝標記 id（`album_children` 分組）。
final class AlbumsContentAssemblerTests: XCTestCase {
    func test_emptyRows_returnsEmptyWithoutCallingAPIClient() async throws {
        let stub = StubAlbumsAPIClient()
        stub.setFetchAlbumChildrenHandler { _ in
            XCTFail("空陣列不應該發請求")
            return []
        }

        let result = try await AlbumsContentAssembler.assemble(rows: [], apiClient: stub)

        XCTAssertTrue(result.isEmpty)
    }

    /// M1：張數不再由這裡計算，`AlbumListingRow.photoCount`（PostgREST aggregate 算好的值）
    /// 應該原樣轉發到 `AlbumSummary.photoCount`，這裡只釘住轉發沒有寫錯欄位。
    func test_photoCount_passesThroughFromRowUnchanged() async throws {
        let rows = [
            AlbumListingRow(id: UUID(), title: "相簿 A", coverMediaId: nil, createdAt: Date(), photoCount: 12),
            AlbumListingRow(id: UUID(), title: "相簿 B", coverMediaId: nil, createdAt: Date(), photoCount: 0)
        ]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.map(\.photoCount), [12, 0])
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

    // MARK: - 封面（merge-review R1 M3：cover_media_id 優先，否則退回內嵌最新一筆）

    func test_coverMediaId_present_resolvesSignedCoverUsingThumbPathPriority() async throws {
        let albumID = UUID()
        let coverMediaID = UUID()
        let rows = [
            AlbumListingRow(
                id: albumID, title: "相簿", coverMediaId: coverMediaID, createdAt: Date(),
                // 就算內嵌 fallback 欄位剛好有值，`cover_media_id` 存在時也該優先用它，不是
                // 誤用 fallback。
                latestMediaThumbPath: "f/should-not-be-used-thumb.jpg",
                latestMediaStoragePath: "f/should-not-be-used-full.jpg"
            )
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
            XCTAssertEqual(paths, ["f/thumb.jpg"], "應該簽 cover_media_id 指到的縮圖路徑，不是原圖或 fallback 路徑")
            return ["f/thumb.jpg": URL(string: "https://example.com/signed-thumb.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/signed-thumb.jpg"))
    }

    /// merge-review R1 M3（票文 Scope 1 原意，本票補上）：`cover_media_id` 未指定時，退回
    /// `AlbumListingRow` 內嵌查詢已經算好的「最新一筆 album_media」縮圖路徑——不再呼叫
    /// `fetchMedia`（那支只服務 `cover_media_id` 顯式指定的情況），也不用另外查 `album_media`。
    func test_coverMediaId_nil_fallsBackToEmbeddedLatestMediaThumbPath() async throws {
        let albumID = UUID()
        let rows = [
            AlbumListingRow(
                id: albumID, title: "相簿", coverMediaId: nil, createdAt: Date(),
                latestMediaThumbPath: "f/latest-thumb.jpg", latestMediaStoragePath: "f/latest-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setFetchMediaHandler { ids in
            XCTFail("未指定封面時不應該呼叫 fetchMedia，收到 ids=\(ids)")
            return []
        }
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/latest-thumb.jpg"], "應該優先簽 fallback 的縮圖路徑，不是原圖")
            return ["f/latest-thumb.jpg": URL(string: "https://example.com/latest-thumb.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/latest-thumb.jpg"))
    }

    /// fallback 縮圖路徑為 `nil`（既有列、縮圖產生失敗）時退回原圖路徑——同
    /// `cover_media_id` 分支「thumb 優先、缺了退回 storage_path」的既有規則。
    func test_coverMediaId_nil_fallbackThumbPathNil_fallsBackToStoragePath() async throws {
        let rows = [
            AlbumListingRow(
                id: UUID(), title: "相簿", coverMediaId: nil, createdAt: Date(),
                latestMediaThumbPath: nil, latestMediaStoragePath: "f/latest-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/latest-full.jpg"])
            return ["f/latest-full.jpg": URL(string: "https://example.com/latest-full.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/latest-full.jpg"))
    }

    /// 相簿沒有任何照片（`cover_media_id` 與內嵌 fallback 皆為 `nil`）時，封面是 `nil`，且
    /// 不應該發任何簽名請求（同既有「空陣列不發請求」慣例）。
    func test_noCoverAndNoFallback_resultsInNilCover_withoutSigningRequest() async throws {
        let rows = [AlbumListingRow(id: UUID(), title: "空相簿", coverMediaId: nil, createdAt: Date(), photoCount: 0)]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTFail("沒有任何封面路徑時不應該發簽名請求，收到 paths=\(paths)")
            return [:]
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
