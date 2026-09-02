import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseTimelineAPIClient` 對 `get_family_timeline` RPC 與 `diaries`／`diary_media`／
/// `albums`／`media` 直接讀取、Storage 簽名 URL 的編碼/解碼與錯誤映射。用 `MockURLProtocol`
/// 攔截請求（不打真網路），同 `SupabaseChildAPIClientTests` 的模式。
final class SupabaseTimelineAPIClientTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let childID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let refID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - fetchTimelinePointers

    func test_fetchTimelinePointers_firstPage_omitsCursorKeys() async throws {
        let client = TestSupabaseClient.make { [familyID, refID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_family_timeline")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_limit"] as? Int, 20)
            // 第一頁：游標兩個 key 應整個省略（get_family_timeline 5 個具名參數皆有 SQL
            // 預設值，省略等同套用預設，見 SupabaseTimelineAPIClient 文件註解）。
            XCTAssertFalse(payload.keys.contains("p_cursor_occurred_at"))
            XCTAssertFalse(payload.keys.contains("p_cursor_ref_id"))
            XCTAssertFalse(payload.keys.contains("p_child_id"))
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "kind": "diary",
              "ref_id": "\(refID.uuidString)",
              "occurred_at": "2026-09-02T08:00:00Z",
              "child_ids": []
            }]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let pointers = try await apiClient.fetchTimelinePointers(
            familyID: familyID, childID: nil, cursor: nil, limit: 20
        )

        XCTAssertEqual(pointers.count, 1)
        XCTAssertEqual(pointers[0].kind, .diary)
        XCTAssertEqual(pointers[0].refId, refID)
        XCTAssertEqual(pointers[0].childIds, [])
    }

    func test_fetchTimelinePointers_withCursorAndChildID_sendsBothCursorKeysTogether() async throws {
        let cursorRefID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let client = TestSupabaseClient.make { [familyID, childID, cursorRefID] request in
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_id"] as? String, childID.uuidString)
            // LS022 半游標守門：呼叫端一律兩個游標欄位一起傳，不會只傳一個。
            XCTAssertEqual(payload["p_cursor_ref_id"] as? String, cursorRefID.uuidString)
            let cursorOccurredAt = try XCTUnwrap(payload["p_cursor_occurred_at"] as? String)
            XCTAssertTrue(cursorOccurredAt.hasSuffix("Z"), "游標時間應明確帶 'Z' 時區指示")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)
        let cursor = TimelineCursor(occurredAt: Date(timeIntervalSince1970: 1_756_800_000), refId: cursorRefID)

        let pointers = try await apiClient.fetchTimelinePointers(
            familyID: familyID, childID: childID, cursor: cursor, limit: 20
        )

        XCTAssertTrue(pointers.isEmpty)
    }

    func test_fetchTimelinePointers_halfCursorError_mapsToRejected() async {
        // LS022（timelineCursorIncomplete）游標是呼叫端自己組出來的，不是使用者輸入
        // ——`LSErrorCode.tier` 把它歸在 `.rejected`（不是 `.validationRetryable`：使用者
        // 沒有「換個輸入再送」這個動作可做，見 AppError.swift 文件註解）。
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS022","message":"游標參數必須成對傳入"}
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        do {
            _ = try await apiClient.fetchTimelinePointers(familyID: familyID, childID: nil, cursor: nil, limit: 20)
            XCTFail("LS022 應該要 throw")
        } catch let error as AppError {
            guard case .rejected(_, let code) = error else {
                return XCTFail("LS022 應映射為 .rejected，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS022")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - fetchDiaries / fetchAlbums / fetchMedia / fetchDiaryMediaLinks

    func test_fetchDiaries_emptyIDs_returnsEmptyWithoutRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不應該發請求")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)
        let diaries = try await apiClient.fetchDiaries(ids: [])
        XCTAssertTrue(diaries.isEmpty)
    }

    func test_fetchDiaries_decodesEntryDateAsPlainDate() async throws {
        let client = TestSupabaseClient.make { [refID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/diaries")
            XCTAssertEqual(request.url?.query?.contains(refID.uuidString), true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(refID.uuidString)",
              "body": "今天第一次翻身",
              "entry_date": "2026-09-01",
              "created_at": "2026-09-01T10:00:00Z"
            }]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let diaries = try await apiClient.fetchDiaries(ids: [refID])

        XCTAssertEqual(diaries.count, 1)
        XCTAssertEqual(diaries[0].body, "今天第一次翻身")
        XCTAssertEqual(BirthdayFormat.displayString(from: diaries[0].entryDate), "2026年9月1日")
    }

    func test_fetchAlbums_decodesRows() async throws {
        let client = TestSupabaseClient.make { [refID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/albums")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id": "\(refID.uuidString)", "title": "生日派對", "cover_media_id": null}]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let albums = try await apiClient.fetchAlbums(ids: [refID])

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].title, "生日派對")
        XCTAssertNil(albums[0].coverMediaId)
    }

    func test_fetchMedia_decodesPhotoRow() async throws {
        let client = TestSupabaseClient.make { [refID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/media")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{
              "id": "\(refID.uuidString)", "storage_path": "f/2026/09/x.jpg",
              "type": "photo", "width": 1200, "height": 900
            }]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let media = try await apiClient.fetchMedia(ids: [refID])

        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media[0].type, .photo)
        XCTAssertEqual(media[0].width, 1200)
    }

    func test_fetchDiaryMediaLinks_decodesSortOrder() async throws {
        let diaryID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let mediaID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/diary_media")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"diary_id": "\(diaryID.uuidString)", "media_id": "\(mediaID.uuidString)", "sort_order": 2}]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let links = try await apiClient.fetchDiaryMediaLinks(diaryIds: [diaryID])

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].sortOrder, 2)
    }

    // MARK: - signedURLs

    func test_signedURLs_emptyPaths_returnsEmptyWithoutRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不應該發請求")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)
        let urls = try await apiClient.signedURLs(forStoragePaths: [])
        XCTAssertTrue(urls.isEmpty)
    }

    func test_signedURLs_partialFailure_omitsFailedPathButKeepsSucceeded() async throws {
        let client = TestSupabaseClient.make { request in
            XCTAssertTrue(request.url?.path.contains("/object/sign/media") == true)
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [
              {"path": "f/ok.jpg", "signedURL": "/object/sign/media/f/ok.jpg?token=abc"},
              {"path": "f/bad.jpg", "error": "not found"}
            ]
            """.utf8))
        }
        let apiClient = SupabaseTimelineAPIClient(client: client)

        let urls = try await apiClient.signedURLs(forStoragePaths: ["f/ok.jpg", "f/bad.jpg"])

        XCTAssertNotNil(urls["f/ok.jpg"])
        XCTAssertNil(urls["f/bad.jpg"], "簽名失敗的路徑不應該出現在結果字典裡")
    }
}
