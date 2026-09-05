import Foundation
@testable import LittleSprout
import XCTest

/// LS-167：`UploadQueueStore` 的防禦性／邊界情境測試——拆自 `UploadQueueStoreTests`（merge-review
/// R4：加完 R3 N1 的回歸測試後那支檔案超過 SwiftLint `type_body_length` 上限，理由同
/// `DiaryComposerStorePublishTests`／`DiaryComposerStorePublishRetryTests` 的既有拆檔慣例）。
/// 涵蓋：重複 id 不覆寫 in-flight 項目（F1）、完成／不可重試失敗後釋放 payload（F3）、
/// `failedCount`（F5）、payload 遺失時 fail loud（R3 i1）、advance／finish 連續觸發不重複啟動
/// 同一筆（R3 N1）。`makeUpload`／`waitUntil` 與 `UploadQueueStoreTests` 各自維護一份——兩邊都
/// 很短，拆成共用 helper 檔案的重複消除效益不值得多一個檔案的間接層。
@MainActor
final class UploadQueueStoreDefensiveTests: XCTestCase {
    private let familyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeUpload(tag: String, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    /// `FamilyStoreInviteRaceTests` 既有的輪詢慣例：限時等到某個條件成立，逾時直接
    /// `XCTFail`（不是靜默通過），避免卡死整個測試行程。
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

    // MARK: - merge-review R2 F1：重複 id 不覆寫 in-flight 項目

    func test_enqueue_duplicateID_doesNotOverwriteInFlightEntry() {
        let mediaService = StubMediaUploadService()
        var tick = 0
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 1,
            now: {
                tick += 1
                return Date(timeIntervalSince1970: TimeInterval(tick))
            }
        )
        let id = UUID()

        store.enqueue([makeUpload(tag: "first", id: id)])
        let firstEnqueuedAt = store.rows.first?.enqueuedAt
        store.enqueue([makeUpload(tag: "duplicate", id: id)])

        XCTAssertEqual(store.rows.count, 1, "重複 id 不該新增第二筆")
        XCTAssertEqual(store.rows.map(\.id), [id], "order 不該出現重複 id")
        XCTAssertEqual(
            store.rows.first?.enqueuedAt, firstEnqueuedAt,
            "第二次 enqueue 用同一個 id 不該覆寫第一筆的 enqueuedAt（用時間戳證明整筆沒被換掉，" +
            "不是只湊巧 id 一樣）"
        )
    }

    // MARK: - merge-review R2 F3：完成／不可重試失敗後釋放 payload

    func test_completedItem_releasesPayload() async {
        let mediaService = StubMediaUploadService()
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 1)
        let upload = makeUpload(tag: "release-me")

        store.enqueue([upload])
        await waitUntil { store.remainingCount == 0 }

        XCTAssertNil(store.debugPayload(upload.id), "完成後應該釋放 payload，只留縮圖與 metadata")
    }

    func test_nonRetryableFailure_releasesPayload() async {
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, _, _, _ in
            throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        let upload = makeUpload(tag: "quota")

        store.enqueue([upload])
        await waitUntil { store.sections.contains { $0.kind == .failed } }

        XCTAssertNil(store.debugPayload(upload.id), "LS002 不可重試——失敗定案後也該釋放 payload")
    }

    func test_retryableFailure_keepsPayload() async {
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        let upload = makeUpload(tag: "network")

        store.enqueue([upload])
        await waitUntil { store.sections.contains { $0.kind == .failed } }

        XCTAssertNotNil(store.debugPayload(upload.id), "可重試的失敗必須留著 payload，retry 才有東西可送")
    }

    // MARK: - merge-review R2 F5：failedCount

    func test_failedCount_countsAllFailuresIncludingQuota() async {
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = String(bytes: data, encoding: .utf8)!
            if tag == "quota" {
                throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
            }
            throw AppError.network(message: "offline")
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 2)

        store.enqueue([makeUpload(tag: "quota"), makeUpload(tag: "network")])
        await waitUntil { store.failedCount == 2 }

        XCTAssertEqual(store.failedCount, 2, "failedCount 含 LS002，不是只算可重試的")
        XCTAssertEqual(store.retryableFailedCount, 1, "retryableFailedCount 仍舊只算可重試的")
    }

    // MARK: - merge-review R3 i1：payload 遺失時不該永遠卡在 .waiting

    func test_start_missingPayloadWhileWaiting_failsInsteadOfHangingForever() async {
        let mediaService = StubMediaUploadService()
        let gate = AsyncStream<Void>.makeStream()
        mediaService.setUploadPhotoHandler { _, _, _, _ in
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 1)
        let blocking = makeUpload(tag: "blocking")
        let broken = makeUpload(tag: "broken")

        store.enqueue([blocking, broken])
        XCTAssertEqual(store.waitingCount, 1, "並發上限 1：第二筆應該卡在等候中")

        // 人為打破「.waiting 一定有 payload」的不變量——正常流程走不到這裡，見
        // `debugForcePayloadNil` 文件註解。
        store.debugForcePayloadNil(broken.id)

        gate.continuation.finish()
        await waitUntil { store.waitingCount == 0 }

        guard case .failed(let reason) = store.rows.first(where: { $0.id == broken.id })?.state else {
            return XCTFail("payload 遺失時不該永遠卡在 .waiting，應該翻成失敗")
        }
        XCTAssertEqual(reason, .server)
    }

    // MARK: - merge-review R3 N1：advance／finish 連續觸發不該重複啟動同一筆

    func test_advance_concurrentCompletions_neverDoubleStartsSameItem() async {
        let mediaService = StubMediaUploadService()
        let gates = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let index = Int(String(bytes: data, encoding: .utf8)!)!
            var iterator = gates[index].stream.makeAsyncIterator()
            _ = await iterator.next()
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 2)
        store.enqueue((0..<4).map { makeUpload(tag: "\($0)") })
        await waitUntil { mediaService.uploadPhotoCalls.count == 2 }

        // 前兩把幾乎同時放行，逼 finish→advance 在極短時間內連續觸發遞補下兩筆；如果
        // `start(_:)` 對非 `.waiting` 項目沒有防禦（N1），這裡有機會把同一個 id 重複送進
        // `performUpload`。
        gates[0].continuation.finish()
        gates[1].continuation.finish()
        await waitUntil { mediaService.uploadPhotoCalls.count == 4 }
        gates[2].continuation.finish()
        gates[3].continuation.finish()
        await waitUntil { store.remainingCount == 0 }

        XCTAssertEqual(
            mediaService.uploadPhotoCalls.count, 4,
            "四筆各自只該被 start／上傳一次；重複啟動會讓呼叫次數超過張數"
        )
    }
}
