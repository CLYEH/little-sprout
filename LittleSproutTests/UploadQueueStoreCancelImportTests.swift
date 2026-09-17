import Foundation
@testable import LittleSprout
import XCTest

/// LS-304：`UploadQueueStore.cancelPendingImportItems`（04b「取消匯入」確認後的清理）——涵蓋
/// 檔頭文件註解列出的三個分支：`.waiting`／`.failed`（釋放 payload／清暫存檔）、`.uploading`
/// （只移除本地簿記，不動 payload／暫存檔）、`.completed`（不移除）。`onUploadFailedTerminal`
/// 掛鉤在每一筆真的被移除時都要呼叫（讓呼叫端解除相簿登記）。
@MainActor
final class UploadQueueStoreCancelImportTests: XCTestCase {
    private let familyID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    private func makePhotoUpload(tag: String, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        FileManager.default.createFile(atPath: url.path, contents: Data("fake video".utf8))
        return url
    }

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

    /// `.waiting`（超過並發上限、還沒開始）——移除後不再出現在 `rows`，`onUploadFailedTerminal`
    /// 有被呼叫一次。
    func test_cancelPendingImportItems_removesWaitingEntry_callsOnUploadFailedTerminal() {
        var terminatedIDs: [UUID] = []
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: StubMediaUploadService(), maxConcurrentUploads: 1,
            onUploadFailedTerminal: { terminatedIDs.append($0) }
        )
        let uploading = makePhotoUpload(tag: "uploading")
        let waiting = makePhotoUpload(tag: "waiting")
        // maxConcurrentUploads:1——`enqueue` 同步把第一筆設成 `.uploading`、第二筆留在
        // `.waiting`（同 `UploadQueueStoreTests.test_enqueue_startsUpToMaxConcurrentUploads_*`
        // 既有慣例：不需要 `await`，這裡的同步斷言就已經是目標狀態）。
        store.enqueue([uploading, waiting])
        XCTAssertEqual(store.rows.first { $0.id == waiting.id }?.state, .waiting)

        let removedCount = store.cancelPendingImportItems([waiting.id])

        XCTAssertEqual(removedCount, 1)
        XCTAssertNil(store.rows.first { $0.id == waiting.id }, "取消後不該再出現在 rows")
        XCTAssertNotNil(store.rows.first { $0.id == uploading.id }, "沒有被取消的那筆不受影響")
        XCTAssertEqual(terminatedIDs, [waiting.id])
    }

    /// `.uploading`（已經在飛行中）——移除後不再出現在 `rows`，但**不**清理 payload／暫存檔
    /// （檔頭文件註解：那個仍在飛行中的 `Task` 可能還在讀取，這裡砍掉會壞了那個 Task）。
    func test_cancelPendingImportItems_removesUploadingEntry_withoutTouchingVideoTempFile() {
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let video = PendingUpload(
            kind: .video(fileURL: tempFile, fileExtension: "mov"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
        store.enqueue([video])
        XCTAssertEqual(store.rows.first?.state, .uploading(progress: nil))

        let removedCount = store.cancelPendingImportItems([video.id])

        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempFile.path),
            "飛行中的項目取消不該砍掉暫存檔——那個仍在飛行中的 Task 可能還在讀取"
        )
    }

    /// `.failed`（可重試，payload 仍保留供 `retry(_:)` 用）——移除時要釋放 payload／清暫存檔，
    /// 同 `finish(_:state:)` 對不可重試失敗的既有終局清理。
    func test_cancelPendingImportItems_removesRetryableFailedEntry_cleansUpVideoTempFile() async {
        let tempFile = makeTempFile()
        let mediaService = StubMediaUploadService()
        mediaService.setUploadVideoHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        // 同 `UploadQueueStoreVideoCompressionTests` 既有慣例：注入原樣轉呼叫的
        // `videoPreparer`，不對這個假造的 "fake video" 內容跑真的 `AVAssetExportSession`
        // （會因為不是有效影片格式而失敗，測不到我們真正要驗的 `uploadVideo` 拋錯路徑）。
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService,
            videoPreparer: { fileURL in
                VideoTrimmer.UploadSource(fileURL: fileURL, fileExtension: "mov", pixelSize: nil)
            }
        )
        let video = PendingUpload(
            kind: .video(fileURL: tempFile, fileExtension: "mov"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
        store.enqueue([video])
        await waitUntil { store.rows.first?.state == .failed(.network) }
        XCTAssertNotNil(store.debugPayload(video.id), "可重試失敗仍保留 payload 供 retry 用——先確認前提成立")

        let removedCount = store.cancelPendingImportItems([video.id])

        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempFile.path), "取消可重試失敗項目要清掉暫存檔，不留孤兒檔案"
        )
    }

    /// `.completed`——不移除，`onUploadFailedTerminal` 不該對它呼叫。
    func test_cancelPendingImportItems_doesNotRemoveCompletedEntry() async {
        var terminatedIDs: [UUID] = []
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: StubMediaUploadService(),
            onUploadFailedTerminal: { terminatedIDs.append($0) }
        )
        let upload = makePhotoUpload(tag: "done")
        store.enqueue([upload])
        await waitUntil { store.rows.first?.state == .completed }

        let removedCount = store.cancelPendingImportItems([upload.id])

        XCTAssertEqual(removedCount, 0)
        XCTAssertNotNil(store.rows.first { $0.id == upload.id })
        XCTAssertTrue(terminatedIDs.isEmpty)
    }

    /// 不存在的 id（例如已經被別的路徑清掉）安靜跳過，不崩潰、回傳數不算它。
    func test_cancelPendingImportItems_unknownID_isNoOp() {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())
        let removedCount = store.cancelPendingImportItems([UUID()])
        XCTAssertEqual(removedCount, 0)
    }
}
