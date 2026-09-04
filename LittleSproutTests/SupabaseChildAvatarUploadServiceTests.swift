import Foundation
import ImageIO
@testable import LittleSprout
import os
import Supabase
import UIKit
import XCTest

/// `SupabaseChildAvatarUploadService`（LS-169）：路徑組成（`storagePath`，純函式）、成功上傳
/// 時打對路徑＋帶 `x-upsert`（換照片要能覆蓋同一個路徑）、來源圖片看不懂時整段不打網路直接
/// 回傳可讀錯誤。用 `MockURLProtocol` 攔截請求，同 `SupabaseChildAPIClientTests` 的模式。
final class SupabaseChildAvatarUploadServiceTests: XCTestCase {
    private let familyID = UUID(uuidString: "7AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let childID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - storagePath（純函式，不需要網路）

    func test_storagePath_isFamilyAvatarsChildJPG_allLowercased() {
        // Swift 的 UUID().uuidString 預設大寫——這裡刻意傳大寫 UUID 進去，斷言輸出強制小寫
        // （migration 的路徑規約要求小寫正規形，見 20260904060700_avatar_object_path.sql）。
        let upperFamily = UUID(uuidString: "7AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let upperChild = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let path = SupabaseChildAvatarUploadService.storagePath(familyID: upperFamily, childID: upperChild)

        XCTAssertEqual(
            path,
            "\(upperFamily.uuidString.lowercased())/avatars/\(upperChild.uuidString.lowercased()).jpg"
        )
        XCTAssertEqual(path, path.lowercased())
    }

    func test_storagePath_differentChildren_produceDifferentPaths() {
        let pathA = SupabaseChildAvatarUploadService.storagePath(familyID: familyID, childID: childID)
        let pathB = SupabaseChildAvatarUploadService.storagePath(familyID: familyID, childID: UUID())

        XCTAssertNotEqual(pathA, pathB)
    }

    // MARK: - uploadAvatar：成功路徑

    func test_uploadAvatar_success_putsToAvatarsPathWithUpsert_returnsPath() async throws {
        let expectedPath = SupabaseChildAvatarUploadService.storagePath(familyID: familyID, childID: childID)
        let recordedUpsertHeader = OSAllocatedUnfairLock<String?>(initialState: nil)
        let recordedBody = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let client = TestSupabaseClient.make { [expectedPath] request in
            XCTAssertEqual(request.url?.path, "/storage/v1/object/media/\(expectedPath)")
            XCTAssertEqual(request.httpMethod, "POST")
            recordedUpsertHeader.withLock { $0 = request.value(forHTTPHeaderField: "x-upsert") }
            recordedBody.withLock { $0 = request.bodyData }
            return MockURLProtocol.StubResponse(
                statusCode: 200, body: Data("""
                {"Key":"media/\(expectedPath)","Id":"ignored"}
                """.utf8)
            )
        }
        let service = SupabaseChildAvatarUploadService(client: client)
        let photoData = Self.makeSolidColorJPEG(pixelWidth: 800, pixelHeight: 400)

        let resultPath = try await service.uploadAvatar(familyID: familyID, childID: childID, imageData: photoData)

        XCTAssertEqual(resultPath, expectedPath)
        XCTAssertEqual(
            recordedUpsertHeader.withLock { $0 }, "true", "換照片要能覆蓋同一個路徑，upsert 必須是 true"
        )
        // 上傳走 multipart/form-data（同 `SupabaseMediaUploadServiceThumbnailTests` 既有觀察，
        // 見該檔 `extractUploadedFileBytes` 文件註解）——外層 `Content-Type` header 是
        // multipart boundary，不是 `image/jpeg`；這裡改驗證真的有送出非空的檔案內容
        // （bytes 存在），檔案本身的 JPEG 正確性由 `AvatarImageProcessorTests` 覆蓋，
        // 不在這裡重複解析 multipart body。
        let body = try XCTUnwrap(recordedBody.withLock { $0 })
        XCTAssertFalse(body.isEmpty, "應該真的送出了檔案內容")
    }

    // MARK: - uploadAvatar：來源圖片看不懂

    func test_uploadAvatar_undecodableImageData_throwsRejectedWithoutNetworkCall() async {
        let client = TestSupabaseClient.make { _ in
            XCTFail("圖片解不出來時不該打任何網路請求")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
        let service = SupabaseChildAvatarUploadService(client: client)
        let garbageData = Data([0x00, 0x01, 0x02, 0x03])

        do {
            _ = try await service.uploadAvatar(familyID: familyID, childID: childID, imageData: garbageData)
            XCTFail("應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail(".rejected 才對應「這張照片沒辦法用」，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - uploadAvatar：Storage 錯誤分流（m3，LS-169 R1；LS-173 i9 補測）

    /// `mapUploadError` 是 `private static`（同 `MediaUploadService.mapUploadError` 對 413
    /// 的既有慣例），沒辦法直接呼叫、只能像這裡一樣經由真正的 `uploadAvatar` 走一次完整流程
    /// ——`MockURLProtocol` 回一個非 2xx 狀態碼＋`{"statusCode":"403",...}` body（同 LS-169 R1
    /// handoff 實測到的真實 Storage API 回應形狀），驗證 403 被特判成 `.rejected` 而不是落
    /// 籠統的 `.server`「伺服器發生問題」。
    func test_uploadAvatar_forbidden403_mapsToRejectedNotServer() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(
                statusCode: 400,
                body: Data("""
                {"statusCode":"403","message":"new row violates row-level security policy"}
                """.utf8)
            )
        }
        let service = SupabaseChildAvatarUploadService(client: client)
        let photoData = Self.makeSolidColorJPEG(pixelWidth: 800, pixelHeight: 400)

        do {
            _ = try await service.uploadAvatar(familyID: familyID, childID: childID, imageData: photoData)
            XCTFail("應該要 throw")
        } catch let error as AppError {
            guard case .rejected(let message, _) = error else {
                return XCTFail(".rejected 才對應「權限不足」，實際是 \(error)")
            }
            // merge-review R1 n2（8b477108）：票文明寫「文案固定」——先前只驗到走 .rejected
            // 分支，沒有釘住 ChildAvatarUploadService.swift:64 的實際文案字面。
            XCTAssertEqual(message, "沒有權限更新這個孩子的頭像，請確認你仍是這個家庭的成員")
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    /// 非 403 的 `StorageError`（這裡用 404 示範）不該被 403 特判撈走，要沿用
    /// `AppError.map` 的既有分流——`StorageError` 不在 `AppError.map` 認得的型別鏈裡
    /// （`AppError.swift`），未特判的一律落 `.server`。這條測試把「拿掉 403 特判」跟「403
    /// 特判誤判其他狀態碼」兩種 mutation 都釘住。
    func test_uploadAvatar_nonForbiddenStorageError_fallsThroughToServerError() async {
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(
                statusCode: 404,
                body: Data("""
                {"statusCode":"404","message":"not found"}
                """.utf8)
            )
        }
        let service = SupabaseChildAvatarUploadService(client: client)
        let photoData = Self.makeSolidColorJPEG(pixelWidth: 800, pixelHeight: 400)

        do {
            _ = try await service.uploadAvatar(familyID: familyID, childID: childID, imageData: photoData)
            XCTFail("應該要 throw")
        } catch let error as AppError {
            guard case .server = error else {
                return XCTFail("非 403 的 Storage 錯誤應該落 .server（AppError.map 兜底），實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }

    // MARK: - Helpers

    /// 產生一張純色 JPEG——同 `AvatarImageProcessorTests`／`SupabaseMediaUploadServiceThumbnailTests`
    /// 既有慣例，這裡另外一份小型、僅本檔使用的版本。
    private static func makeSolidColorJPEG(pixelWidth: Int, pixelHeight: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight), format: format
        )
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        return image.jpegData(compressionQuality: 1.0)!
    }
}
