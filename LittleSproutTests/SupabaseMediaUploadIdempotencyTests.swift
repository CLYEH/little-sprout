import Auth
import Foundation
@testable import LittleSprout
import os
import Supabase
import UIKit
import XCTest

/// LS-397 merge-review R1 M3：呼叫端指定 `mediaID` 的冪等重送——Storage PUT 用 upsert、`media` 列 INSERT
/// 撞主鍵（`23505`）視為上一次嘗試已 commit（回傳同一個 id、不清理已寫入的物件）；不指定 `mediaID` 的
/// 既有呼叫端行為完全不變（撞主鍵仍然丟錯、PUT 不帶 upsert）。
final class SupabaseMediaUploadIdempotencyTests: XCTestCase {
    private let familyID = UUID(uuidString: "8AAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private struct Recorded {
        var putUpsertHeaders: [String?] = []
        var insertedIDs: [String] = []
        var deleteCount = 0
    }

    /// 假伺服器：PUT 一律成功；INSERT 依 `insertStatus` 回應（409＋`23505` 模擬主鍵已存在）。
    private func makeClient(insertStatus: Int, recorded: OSAllocatedUnfairLock<Recorded>) -> SupabaseClient {
        TestSupabaseClient.make { [userID] request in
            if request.url?.path == "/auth/v1/token" {
                return MockURLProtocol.StubResponse(
                    statusCode: 200, body: SessionFixture.json(userID: userID, email: "owner@example.com")
                )
            }
            if request.httpMethod == "DELETE", request.url?.path.hasPrefix("/storage/v1/object/media") == true {
                recorded.withLock { $0.deleteCount += 1 }
                return MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
            }
            if request.httpMethod == "POST", request.url?.path.hasPrefix("/storage/v1/object/media/") == true {
                recorded.withLock { $0.putUpsertHeaders.append(request.value(forHTTPHeaderField: "x-upsert")) }
                return MockURLProtocol.StubResponse(statusCode: 200, body: Data(#"{"Key":"media/x","Id":"i"}"#.utf8))
            }
            if request.url?.path == "/rest/v1/media" {
                if let body = request.bodyData,
                   let row = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let id = row["id"] as? String {
                    recorded.withLock { $0.insertedIDs.append(id) }
                }
                let body: Data
                switch insertStatus {
                case 201: body = Data()
                case 500: body = Data(#"{"code":"XX000","message":"internal error"}"#.utf8)
                default: body = Data(#"{"code":"23505","message":"duplicate key value violates unique"}"#.utf8)
                }
                return MockURLProtocol.StubResponse(statusCode: insertStatus, body: body)
            }
            XCTFail("未預期的請求：\(request.url?.path ?? "nil")")
            return MockURLProtocol.StubResponse(statusCode: 500, body: Data())
        }
    }

    private func signIn(client: SupabaseClient) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: "fake", nonce: "fake")
        )
    }

    private func photoData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 1.0)!
    }

    /// 指定 `mediaID` 且 INSERT 撞主鍵（上一次嘗試已 commit、回應遺失）：回傳同一個 id、PUT 全帶 upsert、
    /// 不刪任何 Storage 物件（刪了就是刪掉那一列指向的真照片）。
    func test_uploadPhoto_withMediaID_primaryKeyConflict_treatedAsSuccess_noCleanup() async throws {
        let recorded = OSAllocatedUnfairLock(initialState: Recorded())
        let client = makeClient(insertStatus: 409, recorded: recorded)
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)
        let mediaID = UUID()

        let returned = try await service.uploadPhoto(
            familyID: familyID, data: photoData(), fileExtension: "jpg", pixelSize: PixelSize(width: 64, height: 64),
            takenAt: nil, mediaID: mediaID
        )

        XCTAssertEqual(returned, mediaID, "重送撞主鍵要當成功並回傳同一個 media id")
        XCTAssertEqual(
            recorded.withLock { $0.insertedIDs.map { $0.lowercased() } }, [mediaID.uuidString.lowercased()],
            "INSERT 帶的是呼叫端指定的 id"
        )
        XCTAssertEqual(
            recorded.withLock { $0.putUpsertHeaders }.filter { $0 == "true" }.count, 2, "原檔與縮圖 PUT 都要 upsert"
        )
        XCTAssertEqual(recorded.withLock { $0.deleteCount }, 0, "撞主鍵成功路徑不能清掉已寫入的物件")
    }

    /// 不指定 `mediaID` 的既有呼叫端：撞主鍵照舊丟錯並清理、PUT 不帶 upsert——行為不變。
    func test_uploadPhoto_withoutMediaID_primaryKeyConflict_stillThrows_andCleansUp() async throws {
        let recorded = OSAllocatedUnfairLock(initialState: Recorded())
        let client = makeClient(insertStatus: 409, recorded: recorded)
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadPhoto(
                familyID: familyID, data: photoData(), fileExtension: "jpg", pixelSize: PixelSize(width: 64, height: 64)
            )
            XCTFail("既有呼叫端撞主鍵應該丟錯")
        } catch {}

        XCTAssertEqual(recorded.withLock { $0.putUpsertHeaders }.filter { $0 == "true" }.count, 0, "既有呼叫端不 upsert")
        XCTAssertEqual(recorded.withLock { $0.deleteCount }, 1, "既有呼叫端 INSERT 失敗仍照舊清孤兒物件")
    }

    /// R2 N1：冪等重送（指定 `mediaID`）失敗（這裡是 INSERT 回 5xx）時，上一次嘗試可能已 commit 一列指向
    /// **同一路徑**的 `media`——清孤兒會把那列的原檔與縮圖刪掉（列在、檔案沒了，永久破圖）。冪等模式
    /// 一律不清理，孤兒交 LS-213 的「Storage 有物件、沒有 media 列」掃描回收。
    func test_uploadPhoto_withMediaID_insertServerError_doesNotDeleteSamePathObjects() async throws {
        let recorded = OSAllocatedUnfairLock(initialState: Recorded())
        let client = makeClient(insertStatus: 500, recorded: recorded)
        try await signIn(client: client)
        let service = SupabaseMediaUploadService(client: client)

        do {
            _ = try await service.uploadPhoto(
                familyID: familyID, data: photoData(), fileExtension: "jpg",
                pixelSize: PixelSize(width: 64, height: 64), takenAt: nil, mediaID: UUID()
            )
            XCTFail("INSERT 回 5xx 應該丟錯")
        } catch {}

        XCTAssertEqual(
            recorded.withLock { $0.deleteCount }, 0, "冪等重送失敗不能清掉同路徑物件（可能屬於上一次已 commit 的列）"
        )
    }
}
