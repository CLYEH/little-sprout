import Foundation
@testable import LittleSprout
import os
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
            XCTAssertEqual(request.url?.path, "/rest/v1/album_summaries")
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

    /// LS-203：張數與封面 fallback 改讀 `album_summaries` view 的扁平彙總欄，不再組
    /// PostgREST 內嵌 aggregate／embed 查詢——這裡鎖住 select 字串只包含六個彙總欄＋主鍵/
    /// 標題/時間戳，且沒有 `latest.order=`／`latest.limit=` 這類只服務內嵌形狀的修飾詞，SDK
    /// 或後端行為改變時能直接測出來，不會悄悄跟著漂移。
    func test_fetchAlbums_selectsFlatViewColumns_withoutEmbedModifiers() async throws {
        let client = TestSupabaseClient.make { request in
            let query = (request.url?.query ?? "").removingPercentEncoding ?? ""
            for column in [
                "visible_media_count", "latest_media_id", "latest_thumb_path", "latest_storage_path",
                "cover_thumb_path", "cover_storage_path"
            ] {
                XCTAssertTrue(query.contains(column), "select 應包含彙總欄 \(column)，實際 query：\(query)")
            }
            XCTAssertFalse(query.contains("album_media"), "不應該再內嵌 album_media，實際 query：\(query)")
            XCTAssertFalse(query.contains("latest:"), "不應該再用 latest 別名內嵌，實際 query：\(query)")
            XCTAssertFalse(query.contains("latest.order="), "不應該再有內嵌修飾詞，實際 query：\(query)")
            XCTAssertFalse(query.contains("latest.limit="), "不應該再有內嵌修飾詞，實際 query：\(query)")
            XCTAssertTrue(query.contains("order=created_at.desc"), "應依 created_at desc 排序，實際 query：\(query)")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        _ = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)
    }

    /// `album_summaries` 回應是扁平欄位（不是 LS-165 那種巢狀陣列），相簿沒有任何照片時
    /// 六個彙總欄皆為 `NULL`／`0`（view 的 `coalesce(..., 0)` 保證 `visible_media_count`
    /// 非 NULL，其餘五欄皆可為 NULL）。
    func test_fetchAlbums_decodesRows_noPhotos() async throws {
        let client = TestSupabaseClient.make { [albumID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(albumID.uuidString)", "title": "生日派對",
              "created_at": "2026-09-04T10:00:00Z", "visible_media_count": 0,
              "latest_media_id": null, "latest_thumb_path": null, "latest_storage_path": null,
              "cover_thumb_path": null, "cover_storage_path": null
            }]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, albumID)
        XCTAssertEqual(rows[0].title, "生日派對")
        XCTAssertEqual(rows[0].photoCount, 0)
        XCTAssertNil(rows[0].latestMediaId)
        XCTAssertNil(rows[0].latestMediaThumbPath)
        XCTAssertNil(rows[0].latestMediaStoragePath)
        XCTAssertNil(rows[0].coverThumbPath)
        XCTAssertNil(rows[0].coverStoragePath)
    }

    /// 六個彙總欄皆有值的完整形狀——`visible_media_count`／`latest_media_id`／
    /// `latest_thumb_path`／`latest_storage_path`／`cover_thumb_path`／`cover_storage_path`
    /// 逐一解碼正確。
    func test_fetchAlbums_decodesRows_withAllSummaryColumnsPopulated() async throws {
        let latestMediaID = UUID()
        let client = TestSupabaseClient.make { [albumID] _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(albumID.uuidString)", "title": "跨年連假出遊",
              "created_at": "2026-09-04T10:00:00Z", "visible_media_count": 62,
              "latest_media_id": "\(latestMediaID.uuidString)",
              "latest_thumb_path": "f/latest_thumb.jpg", "latest_storage_path": "f/latest.jpg",
              "cover_thumb_path": "f/cover_thumb.jpg", "cover_storage_path": "f/cover.jpg"
            }]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let rows = try await apiClient.fetchAlbums(familyID: familyID, cursor: nil, limit: 20)

        XCTAssertEqual(rows[0].photoCount, 62)
        XCTAssertEqual(rows[0].latestMediaId, latestMediaID)
        XCTAssertEqual(rows[0].latestMediaThumbPath, "f/latest_thumb.jpg")
        XCTAssertEqual(rows[0].latestMediaStoragePath, "f/latest.jpg")
        XCTAssertEqual(rows[0].coverThumbPath, "f/cover_thumb.jpg")
        XCTAssertEqual(rows[0].coverStoragePath, "f/cover.jpg")
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

    /// merge-review R1 major-1：INSERT 改 `.select("id,title,created_at")` 直接取回列，
    /// 本地組出等價的 `AlbumListingRow`（`visible_media_count=0`＋五個 NULL 路徑欄），不再
    /// 向 `album_summaries` 發第二個請求重讀——原本的兩步驟設計在 INSERT 已 commit、重讀
    /// 失敗時會整個 throw，沒有補償，導致重複建立相簿（見票 R2 comment）。這裡鎖住：(a)
    /// INSERT 的 `select=` 只取三欄、(b) 全程只有一個 REST 請求（沒有第二次打
    /// `album_summaries`）、(c) 組出的列張數與四個路徑欄符合「剛建立必為 0／NULL」。
    func test_createAlbum_insertsWithSelectThenBuildsRowLocally_withoutSecondRequest() async throws {
        let restRequestCount = OSAllocatedUnfairLock(initialState: 0)
        let client = TestSupabaseClient.make { [userID, familyID, albumID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            restRequestCount.withLock { $0 += 1 }
            XCTAssertEqual(
                request.url?.path, "/rest/v1/albums",
                "本地組出後不應該再向 album_summaries 發第二個請求（merge-review R1 major-1）"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            let query = (request.url?.query ?? "").removingPercentEncoding ?? ""
            XCTAssertTrue(query.contains("select=id,title,created_at"), "select 應只取三欄，實際 query：\(query)")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["title"], "新相簿")
            XCTAssertEqual(payload["family_id"], familyID.uuidString)
            XCTAssertEqual(payload["created_by"], userID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 201, body: Data("""
            {"id": "\(albumID.uuidString)", "title": "新相簿", "created_at": "2026-09-05T00:00:00Z"}
            """.utf8))
        }
        try await signIn(client: client)
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        let row = try await apiClient.createAlbum(familyID: familyID, title: "新相簿")

        XCTAssertEqual(row.id, albumID)
        XCTAssertEqual(row.title, "新相簿")
        XCTAssertEqual(row.photoCount, 0, "剛建立的相簿必定 0 張照片，本地組出不需要向 view 重讀")
        XCTAssertNil(row.latestMediaId)
        XCTAssertNil(row.latestMediaThumbPath)
        XCTAssertNil(row.latestMediaStoragePath)
        XCTAssertNil(row.coverThumbPath)
        XCTAssertNil(row.coverStoragePath)
        XCTAssertEqual(
            restRequestCount.withLock { $0 }, 1,
            "全程只應該有一個 REST 請求（INSERT），不重讀 album_summaries"
        )
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
