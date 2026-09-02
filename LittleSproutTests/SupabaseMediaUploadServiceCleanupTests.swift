import Auth
import Foundation
@testable import LittleSprout
import os
import Supabase
import UIKit
import XCTest

/// `SupabaseMediaUploadService`：任一 PUT（原檔／縮圖）失敗時批次清掉已上傳的孤兒物件、不
/// `insert media` 列（LS-129）。從 `SupabaseMediaUploadServiceThumbnailTests` 拆出——那支
/// 檔案加完這批測試後超過 SwiftLint `type_body_length` 上限，理由跟
/// `DiaryComposerStorePublishRetryTests` 從 `DiaryComposerStorePublishTests` 拆分一致（見該檔
/// 文件註解）。
final class SupabaseMediaUploadServiceCleanupTests: XCTestCase {
    private let familyID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    /// 縮圖 PUT 失敗、原檔已經先傳成功——清理仍要涵蓋原檔，不能只清縮圖那一個（merge-review
    /// 關注的 race：`uploadOriginalAndThumb` 用 `TaskGroup` 確保兩邊都跑完才進 catch，見該檔
    /// 文件註解）。
    func test_uploadPhoto_thumbPutFails_cleansUpBothOriginalAndThumbObjects_doesNotInsertRow() async throws {
        let photoData = Self.makeTestPhotoJPEGData(pixelWidth: 800, pixelHeight: 800)
        let removedPrefixes = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let client = TestSupabaseClient.make { [userID] request in
            try Self.handlePutFailureRequest(
                request, userID: userID, failingSuffix: "_thumb.jpg", removedPrefixes: removedPrefixes
            )
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadPhoto(
                familyID: familyID, data: photoData, fileExtension: "jpg", pixelSize: PixelSize(width: 800, height: 800)
            )
            XCTFail("縮圖 PUT 失敗應該要 throw")
        } catch is AppError {
            // expected
        }

        let removed = removedPrefixes.withLock { $0 }
        XCTAssertEqual(removed.count, 1, "應該一次批次清掉兩個物件，不是各自呼叫 remove")
        XCTAssertEqual(removed.first?.count, 2, "原檔與縮圖都要被清掉——縮圖 PUT 失敗前原檔已經傳成功了")
    }

    /// 反過來：原檔 PUT 失敗、縮圖已經先傳成功——清理仍要涵蓋縮圖。
    func test_uploadPhoto_originalPutFails_thumbSucceeded_stillCleansUpThumbObject_doesNotInsertRow() async throws {
        let photoData = Self.makeTestPhotoJPEGData(pixelWidth: 800, pixelHeight: 800)
        let removedPrefixes = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let client = TestSupabaseClient.make { [userID] request in
            // failingSuffix: nil → 讓「不是 _thumb.jpg 結尾」的原檔請求失敗（見
            // handlePutFailureRequest 文件註解）。
            try Self.handlePutFailureRequest(
                request, userID: userID, failingSuffix: nil, removedPrefixes: removedPrefixes
            )
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadPhoto(
                familyID: familyID, data: photoData, fileExtension: "jpg", pixelSize: PixelSize(width: 800, height: 800)
            )
            XCTFail("原檔 PUT 失敗應該要 throw")
        } catch is AppError {
            // expected
        }

        let removed = removedPrefixes.withLock { $0 }
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.count, 2, "原檔 PUT 失敗、縮圖已經先傳成功了——清理仍要涵蓋縮圖，不能只清原檔那一個")
    }

    /// 共用的 PUT-失敗 mock handler：`failingSuffix` 指定哪一個物件（`_thumb.jpg` 結尾＝縮圖，
    /// `nil`＝原檔）該回傳失敗，另一個回傳成功；`DELETE /storage/v1/object/media` 記錄批次清理
    /// 呼叫的 `prefixes`。兩支「原檔／縮圖哪個先失敗」的測試共用同一段 request 分流邏輯，只是
    /// 参數不同，避免兩支測試各自重複一大段幾乎一樣的 handler。
    private static func handlePutFailureRequest(
        _ request: URLRequest, userID: UUID, failingSuffix: String?, removedPrefixes: OSAllocatedUnfairLock<[[String]]>
    ) throws -> MockURLProtocol.StubResponse {
        if request.url?.path == "/auth/v1/token" {
            return MockURLProtocol.StubResponse(
                statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
            )
        }
        if let path = request.url?.path, request.httpMethod == "POST", path.hasPrefix("/storage/v1/object/media/") {
            let shouldFail = failingSuffix.map(path.hasSuffix) ?? !path.hasSuffix("_thumb.jpg")
            if shouldFail {
                return MockURLProtocol.StubResponse(
                    statusCode: 500, body: Data("""
                    {"statusCode":"500","error":"boom","message":"put failed"}
                    """.utf8)
                )
            }
            return MockURLProtocol.StubResponse(
                statusCode: 200, body: Data("""
                {"Key":"media/x","Id":"ignored"}
                """.utf8)
            )
        }
        if request.url?.path == "/storage/v1/object/media", request.httpMethod == "DELETE" {
            let body = try XCTUnwrap(request.bodyData)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let prefixes = try XCTUnwrap(json["prefixes"] as? [String])
            removedPrefixes.withLock { $0.append(prefixes) }
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        XCTFail("任一 PUT 失敗就不該 insert：\(request.url?.path ?? "nil")")
        return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
    }

    /// 沒有縮圖（生成失敗的過渡情形）時只有原檔一個 PUT——它自己失敗代表根本沒有任何物件
    /// 真的上傳成功，不該再打一次注定落空的 `DELETE`（同 `insertMediaRow` 失敗時才清理的
    /// 既有慣例：只清「確定已經上傳」的物件，見 `MediaUploadService.swift` 該段落文件註解）。
    func test_uploadVideo_originalPutFails_withNoThumbnail_doesNotAttemptCleanup_doesNotInsertRow() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let client = TestSupabaseClient.make { [userID] request in
            try Self.handleOriginalOnlyPutFailureRequest(request, userID: userID)
        }
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadVideo(
                familyID: familyID, fileURL: tempURL, fileExtension: "mp4",
                pixelSize: PixelSize(width: 1920, height: 1080)
            )
            XCTFail("原檔 PUT 失敗應該要 throw")
        } catch is AppError {
            // expected；handler 裡的 XCTFail 會在真的打了 DELETE／insert 時失敗這個測試。
        }
    }

    private static func handleOriginalOnlyPutFailureRequest(
        _ request: URLRequest, userID: UUID
    ) throws -> MockURLProtocol.StubResponse {
        if request.url?.path == "/auth/v1/token" {
            return MockURLProtocol.StubResponse(
                statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
            )
        }
        if let path = request.url?.path, request.httpMethod == "POST", path.hasPrefix("/storage/v1/object/media/") {
            return MockURLProtocol.StubResponse(
                statusCode: 500, body: Data("""
                {"statusCode":"500","error":"boom","message":"original put failed"}
                """.utf8)
            )
        }
        XCTFail("沒有縮圖時原檔 PUT 失敗，不該有任何後續請求（沒有物件真的上傳成功，無需清理）：\(request.url?.path ?? "nil")")
        return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
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

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }
}
