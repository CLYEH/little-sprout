import Foundation
@testable import LittleSprout
import os
import Supabase
import XCTest

/// `SupabaseAlbumsAPIClient.setMediaChildrenBatch`（LS-319，`set_media_children_batch` RPC，見
/// docs/API.md §4）的編碼與錯誤映射——拆出獨立檔案，理由同 `SupabaseAlbumsAPIClientUpdateAlbumTitleTests`
/// 檔頭：`SupabaseAlbumsAPIClientTests.swift` 已逼近 SwiftLint `file_length` 上限，不再往那個
/// 檔案加。用 `MockURLProtocol` 攔截請求（不打真網路），同該檔既有的模式。
final class SupabaseAlbumsMediaChildrenTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_setMediaChildrenBatch_sendsItemsShape() async throws {
        let mediaA = UUID()
        let mediaB = UUID()
        let babyA = UUID()
        let babyB = UUID()
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_media_children_batch")
            let body = try XCTUnwrap(request.bodyData)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let items = try XCTUnwrap(payload["p_items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0]["media_id"] as? String, mediaA.uuidString)
            XCTAssertEqual(items[0]["child_ids"] as? [String], [babyA.uuidString, babyB.uuidString])
            XCTAssertEqual(items[1]["media_id"] as? String, mediaB.uuidString)
            XCTAssertEqual(items[1]["child_ids"] as? [String], [])
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        try await apiClient.setMediaChildrenBatch(items: [
            MediaChildrenBatchItem(mediaID: mediaA, childIDs: [babyA, babyB]),
            MediaChildrenBatchItem(mediaID: mediaB, childIDs: [])
        ])
    }

    /// `MediaChildrenMarkingTracker` 只在有成功上傳的 media 時才呼叫，這裡再擋一層不信任
    /// 呼叫端——同 `MediaUploadService.softDeleteMedia` 既有的「空陣列合法 no-op」慣例。
    func test_setMediaChildrenBatch_emptyItems_doesNotSendRequest() async throws {
        let client = TestSupabaseClient.make { _ in
            XCTFail("空陣列不該打任何請求")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        try await apiClient.setMediaChildrenBatch(items: [])
    }

    /// docs/API.md §4：`p_child_ids` 任一元素跨家庭 → `23503`（foreign_key_violation）。
    func test_setMediaChildrenBatch_foreignKeyViolation_mapsToValidationRetryableWith23503() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"23503","message":"insert or update on table \\"media_children\\" violates foreign key constraint"}
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            let items = [MediaChildrenBatchItem(mediaID: UUID(), childIDs: [UUID()])]
            try await apiClient.setMediaChildrenBatch(items: items)
            XCTFail("23503 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("23503 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "23503")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    /// docs/API.md §4：批次筆數超過 500 上限 → `22023`（invalid_parameter_value）。
    func test_setMediaChildrenBatch_batchLimitExceeded_mapsToValidationRetryableWith22023() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"22023","message":"批次筆數超過上限（500），實際 501 筆"}
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            try await apiClient.setMediaChildrenBatch(items: [MediaChildrenBatchItem(mediaID: UUID(), childIDs: [])])
            XCTFail("22023 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("22023 應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "22023")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    /// docs/API.md §4：任一元素指向已軟刪孩子 → `LS044`。
    func test_setMediaChildrenBatch_childDeleted_mapsToValidationRetryableWithLS044() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 400, body: Data("""
            {"code":"LS044","message":"寶貝已移除，無法歸屬新內容"}
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            let items = [MediaChildrenBatchItem(mediaID: UUID(), childIDs: [UUID()])]
            try await apiClient.setMediaChildrenBatch(items: items)
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
}
