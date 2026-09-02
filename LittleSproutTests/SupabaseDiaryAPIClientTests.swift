import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseDiaryAPIClient` 對 `create_diary_entry`／`update_diary_entry` 兩支 RPC 與
/// `diary_media` 直接 insert 的編碼與錯誤映射。用 `MockURLProtocol` 攔截請求（不打真網路），
/// 同 `SupabaseChildAPIClientTests` 的模式。
final class SupabaseDiaryAPIClientTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let diaryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let childID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let mediaID1 = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let mediaID2 = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_createDiaryEntry_sendsChildIDsArrayAndPlainDate_decodesID() async throws {
        let client = TestSupabaseClient.make { [familyID, childID, diaryID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/create_diary_entry")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_family_id"] as? String, familyID.uuidString)
            XCTAssertEqual(payload["p_child_ids"] as? [String], [childID.uuidString])
            XCTAssertEqual(payload["p_body"] as? String, "今天很開心")
            XCTAssertEqual(payload["p_entry_date"] as? String, "2026-08-31")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"\(diaryID.uuidString)\"".utf8))
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        let resultID = try await apiClient.createDiaryEntry(
            familyID: familyID, body: "今天很開心", entryDate: utcDate(year: 2026, month: 8, day: 31), childIDs: [childID]
        )

        XCTAssertEqual(resultID, diaryID)
    }

    func test_createDiaryEntry_noChildren_sendsEmptyArray() async throws {
        let client = TestSupabaseClient.make { [diaryID] request in
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_child_ids"] as? [String], [], "不指定＝空陣列，不是省略這個 key")
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("\"\(diaryID.uuidString)\"".utf8))
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        _ = try await apiClient.createDiaryEntry(
            familyID: familyID, body: "沒有指定寶貝", entryDate: utcDate(year: 2026, month: 8, day: 31), childIDs: []
        )
    }

    func test_createDiaryEntry_childDeletedError_mapsToValidationRetryable() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS044","message":"寶貝已移除，無法歸屬新內容"}
            """.utf8))
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        do {
            _ = try await apiClient.createDiaryEntry(
                familyID: familyID, body: "內容", entryDate: utcDate(year: 2026, month: 8, day: 31), childIDs: [childID]
            )
            XCTFail("LS044 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("LS044 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "LS044")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_updateDiaryEntry_sendsFullReplacePayload() async throws {
        let client = TestSupabaseClient.make { [diaryID, childID] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/update_diary_entry")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["p_diary_id"] as? String, diaryID.uuidString)
            XCTAssertEqual(payload["p_body"] as? String, "改過的內容")
            XCTAssertEqual(payload["p_entry_date"] as? String, "2026-08-30")
            XCTAssertEqual(payload["p_child_ids"] as? [String], [childID.uuidString])
            return MockURLProtocol.StubResponse(statusCode: 204, body: Data())
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        try await apiClient.updateDiaryEntry(
            diaryID: diaryID, body: "改過的內容", entryDate: utcDate(year: 2026, month: 8, day: 30), childIDs: [childID]
        )
    }

    func test_updateDiaryEntry_notAuthorError_mapsToRejected() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS021","message":"不是作者本人"}
            """.utf8))
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        do {
            try await apiClient.updateDiaryEntry(
                diaryID: diaryID, body: "內容", entryDate: utcDate(year: 2026, month: 8, day: 30), childIDs: []
            )
            XCTFail("LS021 應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("LS021 應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    func test_attachMedia_insertsRowsWithSortOrderMatchingArrayIndex() async throws {
        let client = TestSupabaseClient.make { [familyID, diaryID, mediaID1, mediaID2] request in
            XCTAssertEqual(request.url?.path, "/rest/v1/diary_media")
            let body = try XCTUnwrap(request.bodyData)
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["media_id"] as? String, mediaID1.uuidString)
            XCTAssertEqual(rows[0]["sort_order"] as? Int, 0)
            XCTAssertEqual(rows[1]["media_id"] as? String, mediaID2.uuidString)
            XCTAssertEqual(rows[1]["sort_order"] as? Int, 1)
            XCTAssertEqual(rows[0]["diary_id"] as? String, diaryID.uuidString)
            XCTAssertEqual(rows[0]["family_id"] as? String, familyID.uuidString)
            return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        try await apiClient.attachMedia(diaryID: diaryID, familyID: familyID, mediaIDs: [mediaID1, mediaID2])
    }

    func test_attachMedia_emptyArray_doesNotSendRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不該打任何請求")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let apiClient = SupabaseDiaryAPIClient(client: client)

        try await apiClient.attachMedia(diaryID: diaryID, familyID: familyID, mediaIDs: [])
    }

    // MARK: - Helpers

    private func utcDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        return utcCalendar.date(from: components)!
    }
}
