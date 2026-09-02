import Auth
import Foundation
import ImageIO
@testable import LittleSprout
import os
import Supabase
import UIKit
import XCTest

/// `SupabaseMediaUploadService` 的縮圖行為（LS-129）：縮圖路徑規約、長邊 ≤512px／JPEG 品質
/// 0.8、原檔＋縮圖並行 PUT、INSERT payload 三欄一次寫入、縮圖產生失敗的降級路徑。任一 PUT
/// 失敗時批次清掉孤兒物件的測試在 `SupabaseMediaUploadServiceCleanupTests`（同樣的拆分理由）。
/// 從 `SupabaseMediaUploadServiceTests` 拆出——那支檔案加完這批測試後超過 SwiftLint
/// `file_length`／`type_body_length` 上限，理由跟 `DiaryComposerStorePublishRetryTests` 從
/// `DiaryComposerStorePublishTests` 拆分一致（見該檔文件註解）。
final class SupabaseMediaUploadServiceThumbnailTests: XCTestCase {
    private let familyID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - 縮圖路徑規約（純函式，不需要網路）

    func test_thumbStoragePath_hasFamilyPrefixAndThumbSuffix_sharesYearMonthAndMediaIDWithStoragePath() {
        let mediaID = UUID(uuidString: "9AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let original = SupabaseMediaUploadService.storagePath(
            familyID: familyID, mediaID: mediaID, fileExtension: "jpg"
        )

        let thumb = SupabaseMediaUploadService.thumbStoragePath(familyID: familyID, mediaID: mediaID)

        XCTAssertTrue(
            thumb.hasPrefix(familyID.uuidString.lowercased() + "/"),
            "縮圖路徑前綴必須是小寫正規形 family_id（media_thumb_path_family_prefix CHECK）"
        )
        XCTAssertTrue(thumb.hasSuffix("_thumb.jpg"), "縮圖路徑尾綴固定 _thumb.jpg（docs/API.md §6）")
        XCTAssertEqual(
            thumb, String(original.dropLast(".jpg".count)) + "_thumb.jpg",
            "縮圖與原檔應該共用同一組 family_id／yyyy／mm／media_id，只有尾綴不同"
        )
    }

    // MARK: - 原檔＋縮圖並行 PUT、INSERT payload 三欄一次寫入

    /// 2000×1000（2:1）真實可解碼 JPEG——縮圖規格是「長邊 ≤512px」，用一張明顯超過門檻的圖
    /// 才能驗到降採樣邏輯真的生效（不是原圖本來就小於門檻，測不出差別）。
    func test_uploadPhoto_success_generatesThumbnail_putsBothInParallel_insertsAllThreeThumbColumns() async throws {
        let photoData = Self.makeTestPhotoJPEGData(pixelWidth: 2000, pixelHeight: 1000)
        let recorded = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        let client = TestSupabaseClient.make { [userID, familyID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            let originalPrefix = "/storage/v1/object/media/\(familyID.uuidString.lowercased())/"
            if let path = request.url?.path, request.httpMethod == "POST", path.hasPrefix(originalPrefix) {
                let fileBytes = try Self.extractUploadedFileBytes(from: request)
                recorded.withLock { $0[path] = fileBytes }
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                recorded.withLock { $0["/rest/v1/media"] = body }
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        let mediaID = try await service.uploadPhoto(
            familyID: familyID, data: photoData, fileExtension: "jpg", pixelSize: PixelSize(width: 2000, height: 1000)
        )
        XCTAssertNotNil(mediaID)

        try assertThumbnailUploadedInParallelAndInserted(calls: recorded.withLock { $0 }, originalData: photoData)
    }

    /// 拆出來的斷言區塊，讓上面那支測試的 body 留在 SwiftLint `function_body_length` 上限內。
    private func assertThumbnailUploadedInParallelAndInserted(calls: [String: Data], originalData: Data) throws {
        let uploadPaths = calls.keys.filter { $0 != "/rest/v1/media" }
        XCTAssertEqual(uploadPaths.count, 2, "原檔與縮圖應該各自 PUT 一次（並行發出，見 uploadOriginalAndThumb 文件註解）")
        let thumbPathKey = try XCTUnwrap(uploadPaths.first { $0.hasSuffix("_thumb.jpg") }, "應該有一次縮圖 PUT")
        let originalPathKey = try XCTUnwrap(uploadPaths.first { $0 != thumbPathKey })
        XCTAssertEqual(calls[originalPathKey], originalData, "原檔 PUT 的內容應該是完整原圖，不是縮圖")
        XCTAssertEqual(
            thumbPathKey, String(originalPathKey.dropLast(".jpg".count)) + "_thumb.jpg",
            "縮圖路徑應該跟原檔共用同一個 media_id"
        )

        let thumbBody = try XCTUnwrap(calls[thumbPathKey])
        XCTAssertEqual(thumbBody.prefix(2), Data([0xFF, 0xD8]), "縮圖應該是 JPEG（magic bytes FF D8）")
        let (thumbWidth, thumbHeight) = try Self.decodedPixelSize(of: thumbBody)
        XCTAssertTrue((505...512).contains(thumbWidth), "縮圖長邊（寬）應貼著 512px 門檻，實際 \(thumbWidth)")
        XCTAssertTrue((248...260).contains(thumbHeight), "縮圖應維持原圖 2:1 長寬比，實際高 \(thumbHeight)")

        let insertBody = try XCTUnwrap(calls["/rest/v1/media"])
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: insertBody) as? [String: Any])
        let expectedThumbPath = thumbPathKey.replacingOccurrences(of: "/storage/v1/object/media/", with: "")
        XCTAssertEqual(row["thumb_path"] as? String, expectedThumbPath)
        XCTAssertEqual(row["thumb_width"] as? Int, thumbWidth)
        XCTAssertEqual(row["thumb_height"] as? Int, thumbHeight)
    }

    // MARK: - 縮圖產生失敗（來源資料看不懂）：不阻斷原檔上傳，thumb_* 三欄留空

    func test_uploadPhoto_thumbnailGenerationFails_stillUploadsOriginal_insertsRowWithNullThumbColumns() async throws {
        // CGImageSource 解不出來的 bytes——makePhotoPendingThumbnail 應該回傳 nil。
        let garbageData = Data([0x00, 0x01, 0x02, 0x03])
        let uploadCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if let path = request.url?.path, request.httpMethod == "POST",
               path.hasPrefix("/storage/v1/object/media/") {
                XCTAssertFalse(path.hasSuffix("_thumb.jpg"), "縮圖生成失敗不該還嘗試 PUT 縮圖物件")
                uploadCount.withLock { $0 += 1 }
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(row["thumb_path"] as? String)
                XCTAssertNil(row["thumb_width"] as? Int)
                XCTAssertNil(row["thumb_height"] as? Int)
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        _ = try await service.uploadPhoto(
            familyID: familyID, data: garbageData, fileExtension: "jpg", pixelSize: PixelSize(width: 1, height: 1)
        )

        XCTAssertEqual(uploadCount.withLock { $0 }, 1, "縮圖生成失敗時只該有一次 storage PUT（原檔）")
    }

    func test_uploadVideo_thumbnailGenerationFails_stillUploadsOriginal_insertsRowWithNullThumbColumns() async throws {
        // 不是合法容器格式的 bytes——AVAssetImageGenerator 讀不出首幀，makeVideoPendingThumbnail
        // 應該回傳 nil。
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let uploadCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let client = TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if let path = request.url?.path, request.httpMethod == "POST",
               path.hasPrefix("/storage/v1/object/media/") {
                XCTAssertFalse(path.hasSuffix("_thumb.jpg"), "影片縮圖生成失敗不該還嘗試 PUT 縮圖物件")
                uploadCount.withLock { $0 += 1 }
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: Data("""
                    {"Key":"media/x","Id":"ignored"}
                    """.utf8)
                )
            }
            if request.url?.path == "/rest/v1/media" {
                let body = try XCTUnwrap(request.bodyData)
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(row["type"] as? String, "video")
                XCTAssertNil(row["thumb_path"] as? String)
                return MockURLProtocol.StubResponse(statusCode: 201, body: Data())
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        _ = try await service.uploadVideo(
            familyID: familyID, fileURL: tempURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(uploadCount.withLock { $0 }, 1, "縮圖生成失敗時只該有一次 storage PUT（原檔）")
    }

    // MARK: - Helpers

    /// 產生一張 `pixelWidth × pixelHeight` 的純色 JPEG——強制 `scale = 1`，確保回傳的 `Data`
    /// 解碼回來的像素尺寸就是傳進去的參數，不會被測試主機螢幕的 Retina scale 放大。
    private static func makeTestPhotoJPEGData(pixelWidth: Int, pixelHeight: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight), format: format
        )
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        return image.jpegData(compressionQuality: 1.0)!
    }

    private static func decodedPixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    enum MultipartExtractionError: Error {
        case missingContentTypeHeader
        case missingBoundary
        case unexpectedBodyShape
        case missingHeaderBodySeparator
    }

    /// `StorageFileApi.upload`把檔案包成 `multipart/form-data`（`cacheControl` 欄位＋檔案本身
    /// 兩個 body part，見 supabase-swift `FileUpload.encode`），送出去的 HTTP body 不是原始
    /// 檔案 bytes——直接拿 `request.bodyData` 跟原圖／縮圖位元組比對一定不相等（多了 multipart
    /// 的 boundary／header 框線）。這裡從 `Content-Type` header 讀出 boundary，照 RFC 2388 的
    /// 框線格式（`BoundaryGenerator`：`--boundary\r\n`…`\r\n--boundary\r\n`…`\r\n--boundary--`）
    /// 切出最後一個 body part（檔案永遠是最後一個 part，`cacheControl` 固定排第一），拆出
    /// header 區塊後剩下的才是真正上傳的原始位元組。
    private static func extractUploadedFileBytes(from request: URLRequest) throws -> Data {
        guard let contentType = request.value(forHTTPHeaderField: "Content-Type") else {
            throw MultipartExtractionError.missingContentTypeHeader
        }
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            throw MultipartExtractionError.missingBoundary
        }
        let boundary = String(contentType[boundaryRange.upperBound...])
        let marker = Data("--\(boundary)".utf8)
        let body = request.bodyData ?? Data()
        var pieces: [Data] = []
        var searchStart = body.startIndex
        while let range = body.range(of: marker, in: searchStart..<body.endIndex) {
            pieces.append(body[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        pieces.append(body[searchStart..<body.endIndex])
        // pieces[0] 是第一個框線之前的內容（永遠是空的）；最後一個 piece 是結尾框線之後的
        // 「--\r\n」殘留；真正的最後一個 body part 夾在中間，是 pieces[count - 2]。
        guard pieces.count >= 3 else { throw MultipartExtractionError.unexpectedBodyShape }
        let lastPartWithHeaders = pieces[pieces.count - 2]
        guard let headerEnd = lastPartWithHeaders.range(of: Data("\r\n\r\n".utf8)) else {
            throw MultipartExtractionError.missingHeaderBodySeparator
        }
        var fileData = lastPartWithHeaders[headerEnd.upperBound...]
        if fileData.suffix(2).elementsEqual(Data("\r\n".utf8)) {
            fileData = fileData.dropLast(2)
        }
        return Data(fileData)
    }

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
