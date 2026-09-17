import Foundation
@testable import LittleSprout
import XCTest

/// LS-304 merge-review R1 m1：`UploadQueueStore.retryRetryable(in:)`——04／05「重試這 N
/// 張」／「重試失敗項（N）」按鈕只該重跑這個批次自己範圍內的可重試失敗列，不是整條共用佇列
/// 的 `retryAllRetryable()`（否則共用佇列裡同時留有「加入照片」單張即傳的失敗列時，按鈕標的
/// N 跟實際重跑的筆數會對不上，見該方法文件註解）。用 `seedForPreview` 直接灌狀態（同
/// `UploadQueueStoreCancelImportTests` 既有慣例）。
@MainActor
final class UploadQueueStoreRetryRetryableInTests: XCTestCase {
    private let familyID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!

    private func waitUntil(
        timeoutSeconds: Double = 1, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                return XCTFail("等待條件成立逾時", file: file, line: line)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func seedFailed(store: UploadQueueStore, reason: UploadFailureReason, tag: String) -> UUID {
        let upload = PendingUpload(
            kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 4)
        )
        store.seedForPreview([.init(upload, enqueuedAt: Date(), state: .failed(reason))])
        return upload.id
    }

    /// 兩筆都是可重試失敗，但只有一筆的 id 在 `ids` 集合裡（模擬「這個批次」）——只有那一筆
    /// 該被翻回 `.waiting` 並重新送出（`retryRetryable(in:)` 同 `retry(_:)`／`retryAllRetryable()`
    /// 既有行為，翻成 `.waiting` 後立刻呼叫 `advance()` 同步開始上傳，`StubMediaUploadService`
    /// 預設立刻成功，因此最終落點是 `.completed`，同 `UploadQueueStoreTests
    /// .test_retryAllRetryable_skipsQuota_retriesOthers` 既有斷言方式）；另一筆（模擬「共用
    /// 佇列裡其他批次／單張即傳的失敗列」）不該被動到，原地維持 `.failed`。
    func test_retryRetryableIn_onlyRetriesEntriesWithinGivenIDs() async {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let inBatchID = seedFailed(store: store, reason: .network, tag: "in-batch")
        let otherBatchID = seedFailed(store: store, reason: .network, tag: "other-batch")

        store.retryRetryable(in: [inBatchID])

        await waitUntil { store.rows.first { $0.id == inBatchID }?.state == .completed }
        XCTAssertEqual(
            store.rows.first { $0.id == otherBatchID }?.state, .failed(.network),
            "不在範圍內的失敗列（模擬其他批次／單張即傳）不該被動到"
        )
    }

    /// 範圍內但不可重試（LS002）的一律不動，同 `retryAllRetryable()` 既有行為。
    func test_retryRetryableIn_skipsNonRetryableWithinRange() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let quotaID = seedFailed(store: store, reason: .quota, tag: "quota")

        store.retryRetryable(in: [quotaID])

        XCTAssertEqual(store.rows.first { $0.id == quotaID }?.state, .failed(.quota), "LS002 不可重試，範圍內也不該被動到")
    }
}
