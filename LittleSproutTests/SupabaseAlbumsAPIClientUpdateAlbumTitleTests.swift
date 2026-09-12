import Foundation
@testable import LittleSprout
import Supabase
import XCTest

/// `SupabaseAlbumsAPIClient.updateAlbumTitle`（merge-review R2 M1）——跟 `SupabaseAlbumsAPIClientTests`
/// 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint `type_body_length`（同
/// `TimelineStoreVideoTests.swift` 的拆檔理由與寫法）。
extension SupabaseAlbumsAPIClientTests {
    func test_updateAlbumTitle_oneRowAffected_doesNotThrow() async throws {
        let albumID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let client = TestSupabaseClient.make { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/albums")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("id=eq.\(albumID.uuidString)"))
            return MockURLProtocol.StubResponse(statusCode: 200, body: Data("""
            [{"id": "\(albumID.uuidString)", "title": "新名字"}]
            """.utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        try await apiClient.updateAlbumTitle(albumID: albumID, title: "新名字")
    }

    /// `albums_update` policy 是 USING 過濾：owner 對別人建立的相簿下 `.update()` 內容欄位時，
    /// UPDATE 語句本身不會出錯，只是匹配 0 列——PostgREST 回 200 + `[]`，不 throw（merge-review
    /// R1 M1）。client 端必須自己把「0 列受影響」翻成錯誤，否則 UI 會顯示「已儲存」但其實
    /// 沒改到（`docs/API.md` §2「靜默 0 列」例外，`AlbumDetailStore.submitEdit` 依此才不會把
    /// 本地 `title` 誤改成新值）。
    func test_updateAlbumTitle_zeroRowsAffected_throwsRejected() async {
        let albumID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let client = TestSupabaseClient.make { _ in
            MockURLProtocol.StubResponse(statusCode: 200, body: Data("[]".utf8))
        }
        let apiClient = SupabaseAlbumsAPIClient(client: client)

        do {
            try await apiClient.updateAlbumTitle(albumID: albumID, title: "新名字")
            XCTFail("非建立者本人（0 列受影響）應該要 throw")
        } catch let error as AppError {
            guard case .rejected = error else {
                return XCTFail("0 列受影響應映射為 .rejected，實際是 \(error)")
            }
        } catch {
            XCTFail("應該 throw AppError，實際是 \(error)")
        }
    }
}
