import Foundation
@testable import LittleSprout
import os
import XCTest

/// `DiaryComposerStore` 影片壓縮結果快取（LS-283 I2／I3，源自 LS-279 merge-review R1
/// `5cd2b2ae`）：上傳失敗重試不重新呼叫 `videoPreparer`、草稿被移除時快取的壓縮輸出要跟著
/// 清掉。從 `DiaryComposerStorePublishRetryTests` 獨立成檔——加進去會超過 SwiftLint
/// `file_length`／`type_body_length` 上限，理由跟既有幾支 `DiaryComposerStore*Tests` 之間的
/// 拆分一致（見那幾支檔案文件註解）。
@MainActor
final class DiaryComposerStoreVideoCacheTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// 這兩條測試會真的把檔案寫進 `MediaDraftTempStorage`（要驗「暫存目錄清空」這件事本身），
    /// 前後各清一次，理由同 `MediaDraftTempStorageTests`：這是行程層級的共用目錄。
    override func setUp() {
        super.setUp()
        MediaDraftTempStorage.purgeStaleFiles()
    }

    override func tearDown() {
        MediaDraftTempStorage.purgeStaleFiles()
        super.tearDown()
    }

    private func makeStore(
        diaryAPIClient: StubDiaryAPIClient = StubDiaryAPIClient(),
        mediaUploadService: StubMediaUploadService = StubMediaUploadService(),
        videoPreparer: @escaping @Sendable (URL) async throws -> VideoTrimmer.UploadSource = { fileURL in
            VideoTrimmer.UploadSource(fileURL: fileURL, fileExtension: "mp4", pixelSize: nil)
        }
    ) -> DiaryComposerStore {
        DiaryComposerStore(
            familyID: familyID, diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService,
            videoPreparer: videoPreparer
        )
    }

    /// I3：上傳失敗重試，同一支影片不該重新呼叫 `videoPreparer`（正式路徑是真的
    /// `AVAssetExportSession.compressedForUpload`，40 秒 4K 在模擬器上約 20 秒——重試每次都重
    /// 壓一次會讓使用者在網路不穩時越試越久）。
    func test_publish_videoUploadFailureThenRetry_reusesCachedCompressedOutput_doesNotReexport() async throws {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        diaryClient.setCreateHandler { _, _, _, _ in UUID() }
        let videoMediaID = UUID()
        let uploadAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        mediaService.setUploadVideoHandler { _, _, _, _ in
            let attempt = uploadAttempts.withLock { state in
                state += 1
                return state
            }
            if attempt == 1 { throw AppError.network(message: "dropped mid-upload") }
            return videoMediaID
        }
        // R2 i2：快取命中要求檔案還在，這裡寫一份真的檔案進共用暫存目錄，不是虛構路徑。
        let compressedURL = try MediaDraftTempStorage.newFileURL(extension: "mp4")
        try Data([0x03]).write(to: compressedURL)
        let videoPreparerCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let store = makeStore(
            diaryAPIClient: diaryClient, mediaUploadService: mediaService,
            videoPreparer: { _ in
                videoPreparerCalls.withLock { $0 += 1 }
                return VideoTrimmer.UploadSource(
                    fileURL: compressedURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
                )
            }
        )
        store.body = "重試不該重新 export"
        store.addVideo(
            fileURL: URL(fileURLWithPath: "/tmp/retry-video-\(UUID().uuidString).mp4"), fileExtension: "mp4",
            duration: 12, pixelSize: PixelSize(width: 3840, height: 2160), previewImage: nil
        )

        let firstResult = await store.publish()
        XCTAssertFalse(firstResult)
        let secondResult = await store.publish()
        XCTAssertTrue(secondResult)

        XCTAssertEqual(
            videoPreparerCalls.withLock { $0 }, 1,
            "同一支影片重試不該重新呼叫 videoPreparer（拿掉快取後這裡會變成 2）"
        )
        XCTAssertEqual(mediaService.uploadVideoCalls.count, 2, "上傳本身失敗了要重打，但用的是同一份壓縮輸出")
        XCTAssertEqual(mediaService.uploadVideoCalls.last?.fileURL, compressedURL)
    }

    /// I2：影片壓完、上傳失敗，使用者接著放棄草稿（`discardDraft`）——快取的壓縮輸出要跟原始
    /// 暫存檔一起清掉，`MediaDraftTempStorage` 的目錄不能留下沒有回收者的孤兒檔（先前只有
    /// App 重啟時的 `purgeStaleFiles()` 會清）。這裡寫真的檔案進共用目錄，直接驗目錄清空這件
    /// 事本身，不只是驗呼叫次數。
    func test_discardDraft_afterFailedVideoUpload_removesCachedCompressedOutputFromTempDirectory() async throws {
        let diaryClient = StubDiaryAPIClient()
        let mediaService = StubMediaUploadService()
        diaryClient.setCreateHandler { _, _, _, _ in UUID() }
        mediaService.setUploadVideoHandler { _, _, _, _ in throw AppError.network(message: "offline") }
        let originalURL = try MediaDraftTempStorage.newFileURL(extension: "mov")
        try Data([0x01]).write(to: originalURL)
        let compressedURL = try MediaDraftTempStorage.newFileURL(extension: "mp4")
        try Data([0x02]).write(to: compressedURL)
        let store = makeStore(
            diaryAPIClient: diaryClient, mediaUploadService: mediaService,
            videoPreparer: { _ in
                VideoTrimmer.UploadSource(fileURL: compressedURL, fileExtension: "mp4", pixelSize: nil)
            }
        )
        store.body = "上傳失敗後放棄"
        store.addVideo(
            fileURL: originalURL, fileExtension: "mov", duration: 12,
            pixelSize: PixelSize(width: 3840, height: 2160), previewImage: nil
        )

        let result = await store.publish()
        XCTAssertFalse(result)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: compressedURL.path),
            "測試前置：上傳失敗後快取的壓縮輸出應該還留著"
        )

        await store.discardDraft()

        let directory = try MediaDraftTempStorage.makeDirectoryIfNeeded()
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            remainingFiles.isEmpty,
            "放棄草稿後暫存目錄應該清空，快取的壓縮輸出跟原始檔都要被回收：\(remainingFiles)"
        )
    }
}
