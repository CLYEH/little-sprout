import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-284：`UploadQueueStore`（相簿批次上傳）影片項目接上 `VideoTrimmer.compressedForUpload`
/// ——沿 `DiaryComposerStorePublishTests` 既有拆檔慣例（同一支 store 的不同關注點各自成檔，
/// 避免單一測試檔撞 SwiftLint `type_body_length`）：壓縮輸出取代原始選片檔案上傳、壓後仍超限
/// 的該項目失敗但不擋其他項目、上傳成功後清掉本機暫存檔。壓縮本身（1080p／60 秒夾／位元率
/// 現算）的行為由 `VideoTrimmerTests` 覆蓋，這裡只測 `UploadQueueStore` 怎麼接這個結果——同
/// `DiaryComposerStorePublishTests.test_publish_withVideoDraft_uploadsCompressedOutputNotDraftOriginal`
/// 用可注入的 `videoPreparer` 假件，不需要真的準備 4K 資產。`makeUpload`／`waitUntil` 與
/// `UploadQueueStoreTests`／`UploadQueueStoreDefensiveTests` 各自維護一份，理由同兩者既有註解。
@MainActor
final class UploadQueueStoreVideoCompressionTests: XCTestCase {
    private let familyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeVideoUpload(fileURL: URL, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .video(fileURL: fileURL, fileExtension: "mp4"), thumbnail: nil,
            pixelSize: PixelSize(width: 3840, height: 2160)
        )
    }

    private func makePhotoUpload(tag: String, id: UUID = UUID()) -> PendingUpload {
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

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data("stub".utf8))
        return url
    }

    // MARK: - 壓縮輸出取代原始檔案（mutation：拿掉 `videoPreparer` 呼叫、直接上傳原檔）

    func test_video_uploadsCompressedOutput_notOriginalPickedFile() async {
        let pickedURL = makeTempFile()
        let compressedURL = makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: pickedURL)
            try? FileManager.default.removeItem(at: compressedURL)
        }
        let preparerCalls = OSAllocatedUnfairLock(initialState: [URL]())
        let mediaService = StubMediaUploadService()
        let videoMediaID = UUID()
        mediaService.setUploadVideoHandler { _, _, _, _ in videoMediaID }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService,
            videoPreparer: { fileURL in
                preparerCalls.withLock { $0.append(fileURL) }
                return VideoTrimmer.UploadSource(
                    fileURL: compressedURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
                )
            }
        )

        store.enqueue([makeVideoUpload(fileURL: pickedURL)])

        await waitUntil { store.sections.contains { $0.kind == .completed } }
        XCTAssertEqual(preparerCalls.withLock { $0 }, [pickedURL], "壓縮步驟要用原始選片檔案呼叫一次")
        guard let call = mediaService.uploadVideoCalls.first else {
            return XCTFail("應該呼叫一次 uploadVideo")
        }
        XCTAssertEqual(mediaService.uploadVideoCalls.count, 1)
        XCTAssertEqual(call.fileURL, compressedURL, "上傳的要是壓縮輸出，不是原始選片檔案")
        XCTAssertEqual(call.fileExtension, "mp4")
        XCTAssertEqual(call.pixelSize, PixelSize(width: 1920, height: 1080), "尺寸要來自壓縮輸出，不是選片當下量到的 4K 尺寸")
    }

    // MARK: - 壓後仍超限：該項失敗、不擋其他項目

    func test_video_compressionExceedsLimit_failsWithVideoTooLargeReason_othersUnaffected() async {
        let pickedURL = makeTempFile()
        defer { try? FileManager.default.removeItem(at: pickedURL) }
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, _, _, _ in UUID() }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 2,
            videoPreparer: { _ in
                throw AppError.validationRetryable(
                    message: "1080p 壓縮後仍有 60000000 bytes／60.0 秒，超過單檔 52428800 bytes 上限",
                    code: DiaryMediaErrorCode.videoTooLargeAfterExport(suggestedSeconds: 6)
                )
            }
        )

        store.enqueue([makeVideoUpload(fileURL: pickedURL), makePhotoUpload(tag: "ok")])

        await waitUntil { store.remainingCount == 1 }
        XCTAssertEqual(mediaService.uploadVideoCalls.count, 0, "壓完仍超限的影片不該被送上 Storage")
        XCTAssertEqual(
            store.sections.first { $0.kind == .completed }?.rows.count, 1, "另一筆照片不該被這支影片的失敗擋住"
        )
        guard let failedRow = store.sections.first(where: { $0.kind == .failed })?.rows.first else {
            return XCTFail("應該有一筆落在失敗態")
        }
        XCTAssertEqual(
            failedRow.state, .failed(.videoTooLarge(suggestedSeconds: 6)),
            "失敗呈現要顯示「影片太長，請裁到 N 秒內」，不是通用的伺服器忙碌"
        )
        guard case .failed(let reason) = failedRow.state else { return XCTFail("預期失敗態") }
        XCTAssertFalse(reason.isRetryable, "同一支原始檔案重試不會變小，不該提供重試")
    }

    // MARK: - 成功後清掉本機暫存檔

    func test_video_uploadSuccess_cleansUpOriginalAndCompressedTempFiles() async {
        let pickedURL = makeTempFile()
        let compressedURL = makeTempFile()
        let mediaService = StubMediaUploadService()
        mediaService.setUploadVideoHandler { _, _, _, _ in UUID() }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService,
            videoPreparer: { _ in
                VideoTrimmer.UploadSource(fileURL: compressedURL, fileExtension: "mp4", pixelSize: nil)
            }
        )

        store.enqueue([makeVideoUpload(fileURL: pickedURL)])

        await waitUntil { store.sections.contains { $0.kind == .completed } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pickedURL.path), "選片暫存複本應該被清掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: compressedURL.path), "壓縮輸出應該被清掉")
    }
}
