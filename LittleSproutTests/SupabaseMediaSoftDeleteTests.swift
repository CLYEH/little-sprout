import Auth
import Foundation
@testable import LittleSprout
import os
import Supabase
import XCTest

/// `SupabaseMediaUploadService.softDeleteMedia`（LS-212）：`removeSelected()`／
/// `discardDraft()` 移除已上傳孤兒 media 時打的那支 `PATCH /rest/v1/media`——只更新
/// `deleted_at`（`media_update` policy 的欄位級 grant 之一，見 `docs/API.md` §3），不經過任何
/// RPC。從 `SupabaseMediaUploadServiceCleanupTests` 拆開放：那支檔案已經是從
/// `SupabaseMediaUploadServiceThumbnailTests` 拆出來的（type_body_length 上限），這裡是全新
/// 的方法，獨立成一支檔案比繼續往同一支塞乾淨。
final class SupabaseMediaSoftDeleteTests: XCTestCase {
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_softDeleteMedia_sendsPatchWithDeletedAtForGivenIDs() async throws {
        let mediaIDs = [
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        ]
        let capturedRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path == "/rest/v1/media" {
                capturedRequest.withLock { $0 = request }
                return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client, now: { Date(timeIntervalSince1970: 1_788_220_800) })

        try await service.softDeleteMedia(mediaIDs: mediaIDs)

        let request = try XCTUnwrap(capturedRequest.withLock { $0 }, "應該打了一次 /rest/v1/media")
        XCTAssertEqual(request.httpMethod, "PATCH")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("id=in."), "應該用 in 篩選這一批 id，不是逐筆各打一次")
        for mediaID in mediaIDs {
            XCTAssertTrue(
                query.localizedCaseInsensitiveContains(mediaID.uuidString), "查詢字串應該包含 \(mediaID.uuidString)"
            )
        }
        let body = try XCTUnwrap(request.bodyData)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["deleted_at"], "2026-09-01T00:00:00.000Z", "應該送出注入的 clock 算出來的明確帶 'Z' 時間戳")
    }

    /// 空陣列是合法 no-op——不該連 auth session 都不需要就打出任何請求（呼叫端
    /// `DiaryComposerStore.cleanupRemovedDrafts` 已經在自己那層 guard 掉了，這裡是協定實作
    /// 本身也要守住同一件事，不依賴呼叫端一定會先 guard）。
    func test_softDeleteMedia_emptyArray_doesNotSendAnyRequest() async throws {
        let client = TestSupabaseClient.make { request in
            XCTFail("空陣列不該打任何請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let service = SupabaseMediaUploadService(client: client)

        try await service.softDeleteMedia(mediaIDs: [])
    }

    func test_softDeleteMedia_serverError_throwsAppError() async {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data("""
            {"message":"boom"}
            """.utf8))
        }
        let service = SupabaseMediaUploadService(client: client)
        do {
            try await signIn(client: client)
            try await service.softDeleteMedia(mediaIDs: [UUID()])
            XCTFail("伺服器錯誤應該要 throw")
        } catch is AppError {
            // expected
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
