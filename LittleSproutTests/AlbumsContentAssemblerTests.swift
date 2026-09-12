import Foundation
@testable import LittleSprout
import XCTest

/// `AlbumsContentAssembler`——LS-203 之後只剩兩件事：張數原樣轉發（`album_summaries` view
/// 已經套用呼叫者 RLS 算好，見 `AlbumListingRow` 文件註解）、封面 fallback（票文 Scope 2：
/// `cover_thumb_path` → `cover_storage_path` → `latest_thumb_path` → `latest_storage_path`
/// → 灰底）、寶貝標記 id（`album_children` 分組）。封面優先序四段全部來自 view 欄位，不再
/// 呼叫 `fetchMedia` 反查 `cover_media_id`（LS-165 R1 M3 的舊做法）。
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

    /// 張數不由這裡計算，`AlbumListingRow.photoCount`（view 的 `visible_media_count`）應該
    /// 原樣轉發到 `AlbumSummary.photoCount`，這裡只釘住轉發沒有寫錯欄位。
    func test_photoCount_passesThroughFromRowUnchanged() async throws {
        let rows = [
            AlbumListingRow(id: UUID(), title: "相簿 A", createdAt: Date(), photoCount: 12),
            AlbumListingRow(id: UUID(), title: "相簿 B", createdAt: Date(), photoCount: 0)
        ]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.map(\.photoCount), [12, 0])
    }

    /// 票文 Scope 2：`latestMediaId` 本票不消費，只需要原樣轉發供 LS-166 使用。
    func test_latestMediaId_passesThroughFromRowUnchanged() async throws {
        let latestMediaID = UUID()
        let rows = [AlbumListingRow(id: UUID(), title: "相簿", createdAt: Date(), latestMediaId: latestMediaID)]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.latestMediaId, latestMediaID)
    }

    func test_childIds_groupedByAlbumID() async throws {
        let albumID = UUID()
        let childA = UUID()
        let childB = UUID()
        let rows = [AlbumListingRow(id: albumID, title: "相簿", createdAt: Date())]
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

    // MARK: - 封面（票文 Scope 2：四段 fallback，皆直接來自 view 欄位）

    func test_coverThumbPath_present_takesPriorityOverEverythingElse() async throws {
        let rows = [
            AlbumListingRow(
                id: UUID(), title: "相簿", createdAt: Date(),
                latestMediaThumbPath: "f/should-not-be-used-latest-thumb.jpg",
                latestMediaStoragePath: "f/should-not-be-used-latest-full.jpg",
                coverThumbPath: "f/cover-thumb.jpg", coverStoragePath: "f/should-not-be-used-cover-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/cover-thumb.jpg"], "cover_thumb_path 有值時應該優先簽它，不是其餘三段")
            return ["f/cover-thumb.jpg": URL(string: "https://example.com/signed-cover-thumb.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/signed-cover-thumb.jpg"))
    }

    /// `cover_thumb_path` 為 `nil`（既有資料、縮圖產生失敗的過渡列）時退回 `cover_storage_path`
    /// ——同「thumb 優先、缺了退回 storage_path」的既有規則，不落到 `latest_*` 兩段。
    func test_coverThumbPathNil_fallsBackToCoverStoragePath() async throws {
        let rows = [
            AlbumListingRow(
                id: UUID(), title: "相簿", createdAt: Date(),
                latestMediaThumbPath: "f/should-not-be-used-latest-thumb.jpg",
                coverThumbPath: nil, coverStoragePath: "f/cover-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/cover-full.jpg"])
            return ["f/cover-full.jpg": URL(string: "https://example.com/signed-cover-full.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/signed-cover-full.jpg"))
    }

    /// `cover_thumb_path`／`cover_storage_path` 皆為 `nil`（未指定封面，或封面已軟刪／跨家庭
    /// ——view 已經把兩種情況都算成 `nil`，client 端不需要分辨）時退回 `latest_thumb_path`。
    func test_coverPathsNil_fallsBackToLatestThumbPath() async throws {
        let rows = [
            AlbumListingRow(
                id: UUID(), title: "相簿", createdAt: Date(),
                latestMediaThumbPath: "f/latest-thumb.jpg", latestMediaStoragePath: "f/latest-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/latest-thumb.jpg"], "應該優先簽 latest 的縮圖路徑，不是原圖")
            return ["f/latest-thumb.jpg": URL(string: "https://example.com/latest-thumb.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/latest-thumb.jpg"))
    }

    /// 封面與 `latest` 縮圖皆缺，只剩 `latest_storage_path`（既有列、縮圖產生失敗）——四段
    /// fallback 最後一段。
    func test_onlyLatestStoragePathPresent_fallsBackToIt() async throws {
        let rows = [
            AlbumListingRow(id: UUID(), title: "相簿", createdAt: Date(), latestMediaStoragePath: "f/latest-full.jpg")
        ]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTAssertEqual(paths, ["f/latest-full.jpg"])
            return ["f/latest-full.jpg": URL(string: "https://example.com/latest-full.jpg")!]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.first?.cover, URL(string: "https://example.com/latest-full.jpg"))
    }

    /// 相簿沒有任何看得見的照片（四欄皆 `nil`——view 已經把「真的 0 張」與「唯一一張被 RLS
    /// 濾掉」兩種情況統一算成這個形狀）時，封面是 `nil`，且不應該發任何簽名請求。
    func test_allFourFieldsNil_resultsInNilCover_withoutSigningRequest() async throws {
        let rows = [AlbumListingRow(id: UUID(), title: "空相簿", createdAt: Date(), photoCount: 0)]
        let stub = StubAlbumsAPIClient()
        stub.setSignedURLsHandler { paths in
            XCTFail("沒有任何封面路徑時不應該發簽名請求，收到 paths=\(paths)")
            return [:]
        }

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertNil(result.first?.cover)
    }

    /// LS-203：封面優先序不再需要 `fetchMedia`（view 已經把 `cover_media_id` 反查好的路徑
    /// 直接放進列裡）——不管封面走哪一段 fallback，都不應該呼叫這支方法。
    func test_neverCallsFetchMedia() async throws {
        let rows = [
            AlbumListingRow(
                id: UUID(), title: "相簿", createdAt: Date(),
                coverThumbPath: "f/cover-thumb.jpg", coverStoragePath: "f/cover-full.jpg"
            )
        ]
        let stub = StubAlbumsAPIClient()
        stub.setFetchMediaHandler { ids in
            XCTFail("LS-203 之後不應該呼叫 fetchMedia，收到 ids=\(ids)")
            return []
        }
        stub.setSignedURLsHandler { _ in ["f/cover-thumb.jpg": URL(string: "https://example.com/x.jpg")!] }

        _ = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)
    }

    func test_resultOrder_matchesInputRowsOrder() async throws {
        let first = UUID()
        let second = UUID()
        let rows = [
            AlbumListingRow(id: first, title: "第一", createdAt: Date()),
            AlbumListingRow(id: second, title: "第二", createdAt: Date().addingTimeInterval(-1))
        ]
        let stub = StubAlbumsAPIClient()

        let result = try await AlbumsContentAssembler.assemble(rows: rows, apiClient: stub)

        XCTAssertEqual(result.map(\.id), [first, second])
    }
}
