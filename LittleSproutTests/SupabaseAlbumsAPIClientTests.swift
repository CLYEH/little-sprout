import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseAlbumsAPIClient` 對 `albums`／`album_media`／`album_children`／`media` 直接讀取、
/// `set_album_children` RPC、Storage 簽名 URL 的編碼/解碼與錯誤映射。用 `MockURLProtocol`
/// 攔截請求（不打真網路），同 `SupabaseTimelineAPIClientTests` 的模式。
final class SupabaseAlbumsAPIClientTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let albumID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - fetchAlbums

    func test_fetchAlbums_firstPage_filtersFamilyAndExcludesDeleted_noOrFilter() async throws {
        let client = TestSupabaseClient.make { [familyID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/albums")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("family_id=eq.\(familyID.uuidString)"))
            // `PostgrestFilterBuilder.is(_:value:)` 對 `Bool?.none` 的 `rawValue` 是大寫
            // "NULL"（`PostgrestFilterValue` `Optional` extension 的既有實作），不是 "null"。
            XCTAssertTrue(query.contains("deleted_at=is.NULL"), "實際 query：\(query)")
            XCTAssertFalse(query.contains("or="), "第一頁不應該帶 or 游標篩選")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)

        XCTAssertTrue(rows.isEmpty)
    }

    func test_fetchAlbums_withCursor_sendsOrFilterWithBothValues() async throws {
        let cursorID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let cursorDate = Date(timeIntervalSince1970: 1_756_800_000)
        let client = TestSupabaseClient.make { request in
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("or="), "帶游標時應該有 or 篩選，實際 query：\(query)")
            XCTAssertTrue(query.contains(cursorID.uuidString), "or 篩選應該包含游標 id")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)
        let cursor = AlbumsCursor(createdAt: cursorDate, id: cursorID)

        _ = try await apiClient.fetchAlbums(familyID: familyID, cursor: cursor, limit: 20)
    }

    /// merge-review R1 M1：張數與封面 fallback 改內嵌 PostgREST aggregate 查詢，不再整頁抓
    /// `album_media` 在 client 端數——本機已用真實 Supabase CLI 容器實測確認
    /// `db-aggregates-enabled` 可用且這組 select／order／limit 字串回得出正確資料（見
    /// `SupabaseAlbumsAPIClient.listSelect`／`fetchAlbums` 文件註解）。這裡鎖住 query 組出的
    /// 實際字元，SDK 或後端行為改變時能直接測出來，不會悄悄跟著漂移。
    func test_fetchAlbums_selectsAggregateCountAndLatestFallback_withCorrectOrderAndLimit() async throws {
        let client = TestSupabaseClient.make { request in
            // `URLRequest` 送出前已經把 `(`／`)`／`,` 等字元 percent-encode 過（`request.url?.
            // query` 在這裡回的是編碼後的原始形式，不是解碼過的——同 UUID／純英數的既有斷言
            // 不會露餡，這裡第一次踩到，解碼後比對才可讀）。
            let query = (request.url?.query ?? "").removingPercentEncoding ?? ""
            XCTAssertTrue(query.contains("album_media(count)"), "應該內嵌 count aggregate，實際 query：\(query)")
            XCTAssertTrue(
                query.contains("latest:album_media(media(thumb_path,storage_path,created_at))"),
                "應該用別名 latest 內嵌最新一筆 album_media，實際 query：\(query)"
            )
            XCTAssertTrue(
                query.contains("latest.order=media(created_at).desc"),
                "應該依巢狀 media(created_at) 排序、用別名 latest 當修飾詞前綴（不是 album_media，避免" +
                    "同一張表嵌兩次時 PGRST108 別名歧義），實際 query：\(query)"
            )
            XCTAssertTrue(query.contains("latest.limit=1"), "應該只取最新一筆，實際 query：\(query)")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        _ = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)
    }

    func test_fetchAlbums_decodesRows_includingAggregateCountAndEmptyLatest() async throws {
        let client = TestSupabaseClient.make { [albumID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(albumID.uuidString)", "title": "生日派對", "cover_media_id": null,
              "created_at": "2026-09-04T10:00:00Z", "album_media": [{"count": 0}], "latest": []
            }]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, albumID)
        XCTAssertEqual(rows[0].title, "生日派對")
        XCTAssertNil(rows[0].coverMediaId)
        XCTAssertEqual(rows[0].photoCount, 0)
        XCTAssertNil(rows[0].latestMediaThumbPath)
        XCTAssertNil(rows[0].latestMediaStoragePath)
    }

    /// 本機真人測試撞過的實際回應形狀（見 `AlbumListingRow` 文件註解）：`album_media` 恆為
    /// 一個元素的陣列（不是裸物件、也不是空陣列），`latest` 有照片時是一個元素的陣列，元素
    /// 包一層 `media`。
    func test_fetchAlbums_decodesRows_withPhotosAndLatestFallback() async throws {
        let client = TestSupabaseClient.make { [albumID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(albumID.uuidString)", "title": "跨年連假出遊", "cover_media_id": null,
              "created_at": "2026-09-04T10:00:00Z",
              "album_media": [{"count": 62}],
              "latest": [{"media": {
                "thumb_path": "f/latest_thumb.jpg", "storage_path": "f/latest.jpg",
                "created_at": "2026-09-04T09:00:00Z"
              }}]
            }]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)

        XCTAssertEqual(rows[0].photoCount, 62)
        XCTAssertEqual(rows[0].latestMediaThumbPath, "f/latest_thumb.jpg")
        XCTAssertEqual(rows[0].latestMediaStoragePath, "f/latest.jpg")
    }

    // MARK: - fetchAlbumChildren / fetchMedia

    func test_fetchAlbumChildren_decodesRows() async throws {
        let childID = UUID()
        let client = TestSupabaseClient.make { [albumID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/album_children")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"album_id": "\(albumID.uuidString)", "child_id": "\(childID.uuidString)"}]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let links = try await apiClient.fetchAlbumChildren(albumIds: [albumID])

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].childId, childID)
    }

    func test_fetchMedia_emptyIDs_returnsEmptyWithoutRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不應該發請求")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)
        let rows = try await apiClient.fetchMedia(ids: [])
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - createAlbum

    func test_createAlbum_sendsCreatedByAndDecodesRow() async throws {
        let client = TestSupabaseClient.make { [userID, familyID, albumID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            XCTAssertEqual(request.url?.path, "/rest/v1/albums")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["title"], "新相簿")
            XCTAssertEqual(payload["family_id"], familyID.uuidString)
            XCTAssertEqual(payload["created_by"], userID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 201, body: Data("""
            {
              "id": "\(albumID.uuidString)", "title": "新相簿", "cover_media_id": null,
              "created_at": "2026-09-05T00:00:00Z", "album_media": [{"count": 0}], "latest": []
            }
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let row = try await apiClient.createAlbum(familyID: familyID, title: "新相簿")

        XCTAssertEqual(row.id, albumID)
        XCTAssertEqual(row.title, "新相簿")
        XCTAssertEqual(row.photoCount, 0, "剛建立的相簿必定 0 張照片")
    }

    func test_createAlbum_notSignedIn_throwsRejectedWithoutSendingRequest() async {
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token", "未登入時唯一可能的請求是刷新 token（本測試不預期成功）")
            return MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"error":"invalid_grant","error_description":"session missing"}
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            _ = try await apiClient.createAlbum(familyID: familyID, title: "新相簿")
            XCTFail("未登入應該 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("未登入應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - setAlbumChildren

    func test_setAlbumChildren_sendsAlbumIDAndChildIDs() async throws {
        let childA = UUID()
        let childB = UUID()
        let client = TestSupabaseClient.make { [albumID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_album_children")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_album_id"] as? String, albumID.uuidString)
            XCTAssertEqual(payload["p_child_ids"] as? [String], [childA.uuidString, childB.uuidString])
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        try await apiClient.setAlbumChildren(albumID: albumID, childIDs: [childA, childB])
    }

    func test_setAlbumChildren_albumNotFound_mapsToRejectedWithLS023() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS023","message":"相簿不存在"}
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            try await apiClient.setAlbumChildren(albumID: albumID, childIDs: [])
            XCTFail("LS023 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS023 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS023")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - setAlbumDeleted

    func test_setAlbumDeleted_sendsAlbumIDAndDeletedFlag() async throws {
        let client = TestSupabaseClient.make { [albumID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_album_deleted")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_album_id"] as? String, albumID.uuidString)
            XCTAssertEqual(payload["p_deleted"] as? Bool, true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        try await apiClient.setAlbumDeleted(albumID: albumID, deleted: true)
    }

    // MARK: - signedURLs

    func test_signedURLs_emptyPaths_returnsEmptyWithoutRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不應該發請求")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)
        let urls = try await apiClient.signedURLs(forStoragePaths: [])
        XCTAssertTrue(urls.isEmpty)
    }

    // MARK: - helpers

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
