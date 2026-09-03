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

    // MARK: - 50 MiB 超限：code 分流（螢幕文案本身由 DiaryPublishErrorMessageTests 釘住）

    /// R1 M1：這裡只驗 `code` 有沒有被正確標記成 `payloadTooLarge`——`message` 是給 log／
    /// 除錯用的（`AppError.swift` 檔頭契約），不是螢幕上會出現的字，不在這裡斷言其內容；
    /// 「螢幕上顯示什麼」的斷言在 `DiaryPublishErrorMessageTests`（merge-review R1 I4 指出
    /// 的缺口：先前這裡斷言 `message.contains("50MB")` 測到的是 log 欄位，不是使用者看得到
    /// 的畫面文字）。
    func test_mapUploadError_payloadTooLarge_marksCodeForScreenDispatch() {
        let storageError = StorageError(statusCode: "413", message: "The object exceeded the maximum allowed size")

        let mapped = SupabaseMediaUploadService.mapUploadError(storageError)

        guard case .validationRetryable(_, let code) = mapped else {
            return XCTFail("413 應映射為 .validationRetryable，實際是 \(mapped)")
        }
        XCTAssertEqual(code, DiaryMediaErrorCode.payloadTooLarge)
    }

    func test_mapUploadError_otherStorageError_fallsThroughToAppErrorMap() {
        let storageError = StorageError(statusCode: "404", message: "not found")

        let mapped = SupabaseMediaUploadService.mapUploadError(storageError)

        if case .validationRetryable(_, let code) = mapped, code == DiaryMediaErrorCode.payloadTooLarge {
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
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("應映射為 .validationRetryable，實際是 \(error)")
            }
            // R1 M1／I4：`message` 是 log 用的，畫面文案的斷言在 DiaryPublishErrorMessageTests。
            XCTAssertEqual(code, DiaryMediaErrorCode.payloadTooLarge)
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    /// merge-review R1 m8：讀不到本機暫存檔大小時要 throw，不能靜默把 `byte_size` 寫成 0
    /// ——那一欄是 `families.storage_used_bytes` trigger 的加總來源，寫 0 等於這支影片不佔
    /// 額度。用一個不存在的檔案路徑重現「讀不到屬性」，且不該打任何網路請求（在真的上傳
    /// 之前就該擋下）。
    func test_uploadVideo_missingFileSize_throwsWithoutUploadingOrInsertingRow() async {
        let client = TestSupabaseClient.make { request in
            XCTFail("讀檔案大小失敗應該在打任何網路請求之前就 throw：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let service = SupabaseMediaUploadService(client: client)
        let missingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        do {
            _ = try await service.uploadVideo(
                familyID: familyID, fileURL: missingFileURL, fileExtension: "mp4",
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
            XCTFail("讀不到檔案大小應該要 throw")
        } catch is AppError {
            // fail loud：不靜默把 byte_size 寫成 0，見上方文件註解。
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
