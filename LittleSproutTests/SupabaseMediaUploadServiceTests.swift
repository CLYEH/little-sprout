import Auth
import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseMediaUploadService`：路徑規約（`docs/API.md` §6）、50 MiB 超限錯誤文案、
/// 上傳→寫 `media` 列的兩步驟順序。用 `MockURLProtocol` 攔截請求，同其他 Supabase client 測試
/// 的模式。
final class SupabaseMediaUploadServiceTests: XCTestCase {
    private let familyID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - 路徑規約（純函式，不需要網路）

    func test_storagePath_isLowercasedAndFollowsFamilyYearMonthConvention() {
        let mediaID = UUID(uuidString: "9AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let path = SupabaseMediaUploadService.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: "JPG")

        XCTAssertTrue(path.hasPrefix(familyID.uuidString.lowercased() + "/"), "路徑第一段必須是小寫正規形 family_id")
        XCTAssertTrue(path.hasSuffix(mediaID.uuidString.lowercased() + ".jpg"), "副檔名一律小寫")
        XCTAssertFalse(path.contains(mediaID.uuidString), "不應該出現大寫 UUID（uuidString 預設大寫）")
    }

    func test_storagePath_containsCurrentYearMonth() {
        let mediaID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: Date())
        let expectedYear = String(format: "%04d", components.year ?? 0)
        let expectedMonth = String(format: "%02d", components.month ?? 0)

        let path = SupabaseMediaUploadService.storagePath(familyID: familyID, mediaID: mediaID, fileExtension: "mp4")

        XCTAssertTrue(path.contains("/\(expectedYear)/\(expectedMonth)/"), "yyyy/mm 應取上傳當下（UTC）")
    }

    // MARK: - 50 MiB 超限錯誤文案

    func test_mapUploadError_payloadTooLarge_returnsFriendlyValidationRetryable() {
        let storageError = StorageError(statusCode: "413", message: "The object exceeded the maximum allowed size")

        let mapped = SupabaseMediaUploadService.mapUploadError(storageError)

        guard case .validationRetryable(let message, let code) = mapped else {
            return XCTFail("413 應映射為 .validationRetryable，實際是 \(mapped)")
        }
        XCTAssertTrue(message.contains("50MB"), "文案要讓使用者看得懂超限的是什麼")
        XCTAssertEqual(code, "storage_413")
    }

    func test_mapUploadError_otherStorageError_fallsThroughToAppErrorMap() {
        let storageError = StorageError(statusCode: "404", message: "not found")

        let mapped = SupabaseMediaUploadService.mapUploadError(storageError)

        if case .validationRetryable(_, let code) = mapped, code == "storage_413" {
            XCTFail("非 413 不該被誤判成超限文案")
        }
    }

    // MARK: - 上傳→寫 media 列（兩步驟）

    func test_uploadPhoto_success_putsToStorageThenInsertsMediaRow_returnsID() async throws {
        let photoData = Data("fake-jpeg-bytes".utf8)
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(
                    request.url!.path.hasPrefix("/storage/v1/object/media/\(familyID.uuidString.lowercased())/")
                )
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/\(familyID.uuidString.lowercased())/x.jpg","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(row["family_id"] as? String, familyID.uuidString)
                XCTAssertEqual(row["type"] as? String, "photo")
                XCTAssertEqual(row["byte_size"] as? Int, photoData.count)
                XCTAssertEqual(row["width"] as? Int, 120)
                XCTAssertEqual(row["height"] as? Int, 90)
                XCTAssertEqual(row["uploaded_by"] as? String, userID.uuidString)
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        let mediaID = try await service.uploadPhoto(
            familyID: familyID, data: photoData, fileExtension: "jpg", pixelSize: PixelSize(width: 120, height: 90)
        )

        XCTAssertNotNil(mediaID)
    }

    func test_uploadPhoto_storageRejectsAsTooLarge_throwsFriendlyErrorWithoutInsertingMediaRow() async {
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.url?.path.hasPrefix("/storage/v1/object/media/") == true, request.httpMethod == "POST" {
                return MockURLProtocol.StubResponse(
                    statusCode: 413, body: Data("""
                    {"statusCode":"413","error":"Payload too large","message":"exceeded maximum allowed size"}
                    """.utf8)
                )
            }
            XCTFail("Storage 上傳本身就失敗，不該再打任何後續請求（含 media insert）：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try? await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadPhoto(
                familyID: familyID, data: Data([0x00]), fileExtension: "jpg", pixelSize: PixelSize(width: 1, height: 1)
            )
            XCTFail("超過 50 MiB 應該要 throw")
        } catch let error as AppError {
            guard case .validationRetryable(let message, let code) = error else {
                return XCTFail("應映射為 .validationRetryable，實際是 \(error)")
            }
            XCTAssertEqual(code, "storage_413")
            XCTAssertTrue(message.contains("50MB"))
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - Helpers

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
