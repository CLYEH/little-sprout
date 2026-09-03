import Auth
import AVFoundation
import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseMediaUploadService.uploadVideo` 的影片時長量測（LS-135，`docs/API.md` §3
/// 「影片時長（duration_seconds）」）：量測成功／不足 1 秒／量到 0 秒／量測失敗四條分支各自
/// 該不該阻斷上傳、寫入什麼值。從 `SupabaseMediaUploadServiceTests` 拆出——那支檔案加完這批
/// 測試後超過 SwiftLint `type_body_length`，理由跟 `SupabaseMediaUploadServiceCleanupTests`
/// 從 `SupabaseMediaUploadServiceThumbnailTests` 拆分一致（見該檔文件註解）。
final class SupabaseMediaUploadServiceDurationTests: XCTestCase {
    private let familyID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func test_uploadVideo_success_measuresDurationAndInsertsDurationSeconds() async throws {
        let tempURL = try Self.makeTempVideoFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                XCTAssertTrue(
                    request.url!.path.hasPrefix("/storage/v1/object/media/\(familyID.uuidString.lowercased())/")
                )
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/\(familyID.uuidString.lowercased())/x.mp4","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(row["type"] as? String, "video")
                // 42.7 秒 → max(1, floor(42.7)) = 42（docs/API.md §3：無條件捨去，與
                // VideoDurationFormat／DiaryDurationFormat 同源，不進位）。
                XCTAssertEqual(row["duration_seconds"] as? Int, 42)
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(
            client: client, durationLoader: { _ in CMTime(seconds: 42.7, preferredTimescale: 600) }
        )

        let mediaID = try await service.uploadVideo(
            familyID: familyID, fileURL: tempURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertNotNil(mediaID)
    }

    /// docs/API.md §3：不足 1 秒的影片記為 1，不進位、不寫 0——`0` 會撞
    /// `media_duration_seconds_positive` CHECK。
    func test_uploadVideo_durationBelowOneSecond_roundsUpToOne() async throws {
        let tempURL = try Self.makeTempVideoFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x.mp4","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(row["duration_seconds"] as? Int, 1, "不足 1 秒記為 1，不寫 0")
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(
            client: client, durationLoader: { _ in CMTime(seconds: 0.4, preferredTimescale: 600) }
        )

        _ = try await service.uploadVideo(
            familyID: familyID, fileURL: tempURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
        )
    }

    /// docs/API.md §3：量到的長度 `<= 0` 秒（不是量測失敗，`durationLoader` 正常回傳但值是
    /// `0`）時同樣留 `NULL`，不是寫 `0`——這條分支跟「量測失敗」（下一支測試）是
    /// `measureDurationSeconds` 兩個不同的 guard，各自需要一支測試釘住，不能只測其中一個
    /// 就假設另一個也對。
    func test_uploadVideo_durationZero_insertsNullDurationSeconds_notZero() async throws {
        let tempURL = try Self.makeTempVideoFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x.mp4","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(
                    row["duration_seconds"] as? Int,
                    "量到 0 秒該留 NULL，寫 0 會撞 media_duration_seconds_positive CHECK"
                )
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(
            client: client, durationLoader: { _ in CMTime(seconds: 0, preferredTimescale: 600) }
        )

        let mediaID = try await service.uploadVideo(
            familyID: familyID, fileURL: tempURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertNotNil(mediaID, "量到 0 秒不該阻斷上傳")
    }

    /// 量測失敗（`durationLoader` throw）不阻斷上傳，`duration_seconds` 留 NULL——不是寫 0，
    /// 也不是整支上傳失敗（docs/API.md §3：這是既有的過渡路徑，比照縮圖生成失敗）。
    func test_uploadVideo_durationLoaderThrows_insertsNullDurationSeconds_doesNotBlockUpload() async throws {
        let tempURL = try Self.makeTempVideoFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x.mp4","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(row["duration_seconds"] as? Int, "量測失敗該留 NULL，不是寫 0")
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(
            client: client,
            durationLoader: { _ in throw AppError.server(message: "無法解析真實影片檔的時長", code: nil) }
        )

        let mediaID = try await service.uploadVideo(
            familyID: familyID, fileURL: tempURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertNotNil(mediaID, "量測失敗不該阻斷上傳")
    }

    // MARK: - Helpers

    private static func makeTempVideoFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
