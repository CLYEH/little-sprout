import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-167：`UploadQueueStore` 的並發上限、重試、狀態轉換——需要 `StubMediaUploadService`
/// 與可控 gate 才能測到「同時飛行中的請求數」，跟純函式的 `UploadQueueModelsTests` 分開檔案
/// （同 `DiaryComposerStorePublishTests`／`DiaryComposerStorePublishRetryTests` 的拆檔慣例）。
@MainActor
final class UploadQueueStoreTests: XCTestCase {
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

    // MARK: - 並發上限

    func test_enqueue_startsUpToMaxConcurrentUploads_thenRefillsAsEachCompletes() async {
        let mediaService = StubMediaUploadService()
        let gates = (0..<5).map { _ in AsyncStream<Void>.makeStream() }
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let index = Int(String(bytes: data, encoding: .utf8)!)!
            var iterator = gates[index].stream.makeAsyncIterator()
            _ = await iterator.next()
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 2)
        let uploads = (0..<5).map { makeUpload(tag: "\($0)") }

        store.enqueue(uploads)

        // `enqueue` 同步把前兩筆狀態設成 `.uploading`——不需要等待，見 `UploadQueueStore.start`
        // 的文件註解。
        XCTAssertEqual(store.uploadingCount, 2, "並發上限 2：不該一次把 5 筆全設成 uploading")
        XCTAssertEqual(store.waitingCount, 3)
        await waitUntil { mediaService.uploadPhotoCalls.count == 2 }
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 2, "一次最多只有 2 筆真正打到 uploadPhoto")

        gates[0].continuation.finish()
        await waitUntil { mediaService.uploadPhotoCalls.count == 3 }
        XCTAssertEqual(store.uploadingCount, 2, "完成一筆、遞補一筆之後，同時飛行中的筆數仍是上限 2")
        XCTAssertEqual(store.waitingCount, 2)

        for index in 1..<5 { gates[index].continuation.finish() }
        await waitUntil { store.remainingCount == 0 }
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 5, "全部 5 筆最終都要打到 uploadPhoto")
        XCTAssertEqual(
            store.sections.first { $0.kind == .completed }?.rows.count, 5,
            "全部成功後都該落在 Completed 群"
        )
    }

    func test_enqueue_fewerItemsThanLimit_startsAllImmediately() {
        let mediaService = StubMediaUploadService()
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 3)

        store.enqueue([makeUpload(tag: "a"), makeUpload(tag: "b")])

        XCTAssertEqual(store.uploadingCount, 2)
        XCTAssertEqual(store.waitingCount, 0)
    }

    // MARK: - 失敗＋重試

    func test_failedUpload_networkError_isRetryable_andRetryRestartsIt() async {
        let mediaService = StubMediaUploadService()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        mediaService.setUploadPhotoHandler { _, _, _, _ in
            let count = callCount.withLock { current -> Int in
                current += 1
                return current
            }
            if count == 1 { throw AppError.network(message: "offline") }
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 1)
        store.enqueue([makeUpload(tag: "only")])
        await waitUntil { store.sections.contains { $0.kind == .failed } }
        let failedID = store.rows.first { row in
            if case .failed = row.state { return true }
            return false
        }?.id
        guard let failedID else { return XCTFail("應該有一筆落在失敗態") }
        guard case .failed(let reason) = store.rows.first(where: { $0.id == failedID })?.state else {
            return XCTFail("預期失敗態")
        }
        XCTAssertEqual(reason, .network)

        store.retry(failedID)

        await waitUntil { store.remainingCount == 0 }
        XCTAssertEqual(
            store.sections.first { $0.kind == .completed }?.rows.map(\.id), [failedID],
            "重試後這筆最終要落在 Completed 群"
        )
        XCTAssertEqual(callCount.withLock { $0 }, 2, "重試要真的再打一次 uploadPhoto，不是只改狀態")
    }

    func test_retry_quotaFailure_isNoOp() async {
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, _, _, _ in
            throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService)
        store.enqueue([makeUpload(tag: "quota")])
        await waitUntil { store.sections.contains { $0.kind == .failed } }
        let id = store.rows[0].id

        store.retry(id)

        // 沒有 `await`：`retry` 對不可重試的失敗是同步 no-op，狀態應立即維持不變。
        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 1, "LS002 不可重試——不該再打一次 uploadPhoto")
        guard case .failed(.quota) = store.rows[0].state else {
            return XCTFail("LS002 失敗列的狀態不該被 retry 動到")
        }
    }

    func test_retryAllRetryable_skipsQuota_retriesOthers() async {
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = String(bytes: data, encoding: .utf8)!
            switch tag {
            case "quota": throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
            case "network": throw AppError.network(message: "offline")
            default: return UUID()
            }
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 2)
        store.enqueue([makeUpload(tag: "quota"), makeUpload(tag: "network")])
        await waitUntil {
            store.sections.first { $0.kind == .failed }?.rows.count == 2
        }
        XCTAssertEqual(store.retryableFailedCount, 1, "只有 network 那筆可重試，LS002 不算")

        // 第二次呼叫 handler 一律成功——把上面的 switch 換掉，模擬「重試時網路已經恢復」。
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = String(bytes: data, encoding: .utf8)!
            if tag == "quota" {
                throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
            }
            return UUID()
        }
        store.retryAllRetryable()

        await waitUntil { store.retryableFailedCount == 0 && store.uploadingCount == 0 }
        XCTAssertEqual(store.sections.first { $0.kind == .completed }?.rows.count, 1, "network 那筆重試後成功")
        XCTAssertEqual(
            store.sections.first { $0.kind == .failed }?.rows.count, 1,
            "LS002 那筆完全沒被 retryAllRetryable 動到，仍留在 Failed 群"
        )
    }

    // MARK: - remainingCount／breakdown

    func test_remainingCount_excludesCompleted_includesWaitingUploadingFailed() async {
        // 兩把各自獨立的 gate（不是同一把給兩筆共用）——`AsyncStream` 一旦 `finish()`，之後
        // 任何新建的 iterator 立刻拿到 `nil`，如果兩筆共用同一把 gate，放行 "a" 會連帶讓
        // 「"a" 完成後遞補上來的 "b"」立刻也拿到已 finish 的 gate 而跟著完成，測不出「只放
        // 一筆」的中間態。
        let mediaService = StubMediaUploadService()
        let gateA = AsyncStream<Void>.makeStream()
        let gateB = AsyncStream<Void>.makeStream()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = String(bytes: data, encoding: .utf8)!
            let gate = tag == "a" ? gateA : gateB
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return UUID()
        }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 1)
        store.enqueue([makeUpload(tag: "a"), makeUpload(tag: "b")])

        XCTAssertEqual(store.remainingCount, 2, "一筆上傳中、一筆等候中，兩筆都算「還沒完成」")

        gateA.continuation.finish()
        await waitUntil { store.remainingCount == 1 }
        XCTAssertEqual(store.remainingCount, 1, "完成的那筆不再計入 remainingCount，另一筆遞補上來變 uploading")

        gateB.continuation.finish()
        await waitUntil { store.remainingCount == 0 }
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
}
