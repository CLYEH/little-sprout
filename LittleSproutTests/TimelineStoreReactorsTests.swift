import Foundation
@testable import LittleSprout
import XCTest

/// LS-237（池 `d4bde273`，sweeper `90e4873d`）：`StubTimelineAPIClient` 的
/// `ReactorsHandler`／`reactorsHandler`／`setReactorsHandler(_:)` 宣告後零呼叫——唯一
/// 呼叫端 `LikersListSheet.load()`（透過 `TimelineStore.reactors`）只靠永遠回 `[]` 的
/// preview client 走過，「有按讚者」與「載入失敗→重試」兩個分支（`LikersListSheet.swift:36`
/// headline／`:64-83`／`:85-91` 名單列）完全零覆蓋。抽成獨立檔案（同
/// `TimelineStoreReactionTests` 拆分理由：加進同一個類別會讓那支測試檔逼近 SwiftLint
/// `file_length`／`type_body_length` 上限）。
@MainActor
final class TimelineStoreReactorsTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// 這支驗證 `TimelineStore.reactors` 原樣轉發 `apiClient.reactors` 的結果——
    /// `LikersListSheet.load()` 直接把這個回傳值指派給 `reactors`（見該檔），不做任何轉換。
    func test_reactors_success_returnsReactorListFromAPIClient() async throws {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        let reactors = [
            ReactorRow(userID: UUID(), displayName: "陳志明"),
            ReactorRow(userID: UUID(), displayName: "林美玲")
        ]
        stub.setReactorsHandler { _, _, _ in reactors }
        let store = TimelineStore(apiClient: stub)

        let result = try await store.reactors(kind: .diary, refId: refId, familyID: familyID)

        XCTAssertEqual(result, reactors, "LikersListSheet「有按讚者」分支依賴這裡原樣轉發 apiClient 的結果")
    }

    /// `LikersListSheet.swift:64-83`「載入失敗→重試」分支——`load()` 的 `catch` 把
    /// `apiClient.reactors` 拋出的錯誤存進 `loadError`（顯示訊息＋「重試」鈕），`TimelineStore
    /// .reactors` 本身不做任何映射，原樣往外拋。
    func test_reactors_failure_propagatesErrorForRetryBranch() async {
        let stub = StubTimelineAPIClient()
        let refId = UUID()
        stub.setReactorsHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = TimelineStore(apiClient: stub)

        do {
            _ = try await store.reactors(kind: .diary, refId: refId, familyID: familyID)
            XCTFail("預期拋出錯誤，讓 LikersListSheet 切到「無法載入名單」＋重試")
        } catch let error as AppError {
            XCTAssertEqual(
                error, .network(message: "offline"),
                "應該原樣往外拋，讓 LikersListSheet.load() 自己 AppError.map 顯示訊息／重試鈕"
            )
        } catch {
            XCTFail("應該拋 AppError，實際是 \(error)")
        }
    }
}
