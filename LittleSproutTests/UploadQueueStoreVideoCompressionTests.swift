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

        // LS-305：`remainingCount == 1` 本身無法區分「照片已完成、影片還在 uploading」與
        // 「照片已完成、影片已落地失敗態」——兩者的 remainingCount 都是 1（`.uploading`／
        // `.failed` 對 remainingCount 來說是同一類「非完成」）。影片與照片是同批 enqueue、
        // `maxConcurrentUploads: 2` 下並發啟動的兩個獨立 Task，沒有任何機制保證影片的
        // `videoPreparer` 丟錯（經過 `acquireVideoExportSlot()` 的 await）一定搶在照片的
        // stub 上傳（可能零 await 同步完成）之前落地，導致偶爾在照片剛完成、影片仍
        // `.uploading` 的瞬間就通過這個等待條件，下面第 113 行 `guard` 撲空。改成同時等
        // `failedCount == 1`，把等待條件收斂成測試真正要的終局態（照片完成＋影片失敗各一），
        // 不是產品碼競態。
        await waitUntil { store.remainingCount == 1 && store.failedCount == 1 }
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
        // merge-review R1 i1：不可重試失敗要清掉選片暫存原檔（`videoPreparer` 這裡直接丟錯，
        // 未曾產出壓縮輸出，所以只有 `pickedURL` 要驗）。
        XCTAssertFalse(FileManager.default.fileExists(atPath: pickedURL.path), "超限失敗後選片暫存複本應該被清掉")
    }

    /// merge-review R1 i1：不可重試失敗（LS002 額度已滿）發生在壓縮**成功之後**——`compressedVideoCache`
    /// 這時已經有值，`finish` 要連同快取的壓縮輸出一起清掉，不是只清原始選片複本。
    func test_video_quotaFailureAfterSuccessfulCompression_cleansUpOriginalAndCachedCompressedOutput() async {
        let pickedURL = makeTempFile()
        let compressedURL = makeTempFile()
        let mediaService = StubMediaUploadService()
        mediaService.setUploadVideoHandler { _, _, _, _ in
            throw AppError.rejected(message: "額度已滿", code: LSErrorCode.storageQuotaExceeded.rawValue)
        }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService,
            videoPreparer: { _ in
                VideoTrimmer.UploadSource(fileURL: compressedURL, fileExtension: "mp4", pixelSize: nil)
            }
        )

        store.enqueue([makeVideoUpload(fileURL: pickedURL)])

        await waitUntil { store.sections.contains { $0.kind == .failed } }
        guard case .failed(.quota) = store.rows.first?.state else {
            return XCTFail("預期落在 LS002 失敗態，實際 \(String(describing: store.rows.first?.state))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pickedURL.path), "選片暫存複本應該被清掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: compressedURL.path), "快取的壓縮輸出應該被清掉，不是孤兒檔")
    }

    // MARK: - 可重試失敗後重試：沿用已壓好的輸出（merge-review R1 B1）

    /// 沿 `DiaryComposerStoreVideoCacheTests
    /// .test_publish_videoUploadFailureThenRetry_reusesCachedCompressedOutput_doesNotReexport`
    /// 同款情境搬到 `UploadQueueStore`：上傳（非壓縮）失敗是可重試的，`retry(_:)` 不該讓這支
    /// 影片重新跑一次 `videoPreparer`——40 秒 4K 在正式路徑上一次 export 要數十秒，重試每次都
    /// 重壓會讓網路不穩時的使用者越試越久，且前一次的壓縮輸出會變成沒有回收者的孤兒檔。
    func test_video_retryableUploadFailureThenRetry_reusesCachedCompressedOutput_doesNotReexport() async {
        let pickedURL = makeTempFile()
        let compressedURL = makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: pickedURL)
            try? FileManager.default.removeItem(at: compressedURL)
        }
        let preparerCalls = OSAllocatedUnfairLock(initialState: 0)
        let uploadAttempts = OSAllocatedUnfairLock(initialState: 0)
        let mediaService = StubMediaUploadService()
        let videoMediaID = UUID()
        mediaService.setUploadVideoHandler { _, _, _, _ in
            let attempt = uploadAttempts.withLock { state -> Int in
                state += 1
                return state
            }
            if attempt == 1 { throw AppError.network(message: "dropped mid-upload") }
            return videoMediaID
        }
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService,
            videoPreparer: { _ in
                preparerCalls.withLock { $0 += 1 }
                return VideoTrimmer.UploadSource(
                    fileURL: compressedURL, fileExtension: "mp4", pixelSize: PixelSize(width: 1920, height: 1080)
                )
            }
        )
        let uploadID = UUID()

        store.enqueue([makeVideoUpload(fileURL: pickedURL, id: uploadID)])
        await waitUntil { store.sections.contains { $0.kind == .failed } }
        guard case .failed(.network) = store.rows.first?.state else {
            return XCTFail("預期第一次上傳因網路失敗，實際 \(String(describing: store.rows.first?.state))")
        }
        // PROBE 同款斷言：重試前壓縮輸出還留著（快取命中的前提），不是被提早清掉。
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: compressedURL.path), "測試前置：上傳失敗後快取的壓縮輸出應該還留著"
        )

        store.retry(uploadID)
        await waitUntil { store.sections.contains { $0.kind == .completed } }

        XCTAssertEqual(preparerCalls.withLock { $0 }, 1, "重試應沿用已壓好的輸出（實際 export 次數）")
        XCTAssertEqual(mediaService.uploadVideoCalls.count, 2, "上傳本身失敗了要重打，但用的是同一份壓縮輸出")
        XCTAssertEqual(
            mediaService.uploadVideoCalls.map(\.fileURL), [compressedURL, compressedURL],
            "兩次上傳都該是同一份壓縮輸出，不是各自重新壓一次"
        )
        // 成功後這份壓縮輸出（正在使用中的那一份）該被清掉——第一次壓縮輸出不該留成孤兒。
        XCTAssertFalse(FileManager.default.fileExists(atPath: compressedURL.path), "第一次壓縮輸出不該留成孤兒")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pickedURL.path), "選片暫存複本應該被清掉")
    }

    // MARK: - 影片 export 專屬並行上限 1（mutation：拿掉 acquire／releaseVideoExportSlot）

    /// i2（LS-286，源自 LS-284 merge-review R1 informational `39ce890a`；**LS-288 i2** 改交錯序
    /// 抬鑑別力，源自 LS-286 merge-review R1 informational `dc010dd7`）：`maxConcurrentUploads`
    /// 預設 3 時，3 支影片同時進佇列會有 3 個 `AVAssetExportSession` 同時做 4K→1080p 轉檔、吃滿
    /// 全部名額，排在後面的照片要等。加了 export 專屬並行上限 1 之後，任何時刻同時在跑
    /// `videoPreparer` 的數量不該超過 1，兩張照片不會被擋住。
    ///
    /// **LS-288 i2**：舊版把兩張照片排在 3 支影片**前面**入佇列——`advance()` 只依 `order` 裡
    /// 先進先出挑前 `maxConcurrentUploads` 筆還在等候的項目來開始，照片排最前面時，不管有沒有
    /// export 專屬鎖，照片本來就會被 `advance()` 排進最先的那批 `.uploading`，對「拿掉 slot
    /// gate」這個 mutation 沒有鑑別力（見 `maxObservedConcurrentExports` 以外那兩條斷言：拿掉
    /// gate 照片一樣先完成）。這裡改成**影片先入佇列、照片後入**，並把 `maxConcurrentUploads`
    /// 開大到 5（＝全部項目數），讓 5 筆一開始就同時進入 `.uploading`（不被 `advance()` 的容量
    /// 卡住）——這樣「兩張照片有沒有搶到自己的上傳名額」只取決於 export 專屬鎖擋不擋得住後面
    /// 的影片，不取決於入佇列順序本身：有鎖時第 2 支影片要等第 1 支釋放名額才開始 export，這段
    /// 空檔剛好夠兩張照片各自完成；拿掉鎖後 3 支影片會一起搶著開始 export，跟兩張照片同時起跑，
    /// 兩張照片不再穩定早於第 2 支影片開始 export。
    func test_video_exportConcurrency_cappedAtOne_interleavedOrder_photosCompleteBeforeSecondVideoExportStarts() async {
        let videoURLs = (0..<3).map { _ in makeTempFile() }
        defer { for url in videoURLs { try? FileManager.default.removeItem(at: url) } }
        let maxObservedConcurrentExports = OSAllocatedUnfairLock(initialState: 0)
        let concurrentExports = OSAllocatedUnfairLock(initialState: 0)
        let exportStartOrder = OSAllocatedUnfairLock(initialState: [(url: URL, at: Date)]())
        let mediaService = StubMediaUploadService()
        mediaService.setUploadVideoHandler { _, _, _, _ in UUID() }
        let photoCompletedAt = OSAllocatedUnfairLock(initialState: [UUID: Date]())
        let photoID1 = UUID()
        let photoID2 = UUID()
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService, maxConcurrentUploads: 5,
            onUploadSucceeded: { id, _ in
                guard id == photoID1 || id == photoID2 else { return }
                photoCompletedAt.withLock { $0[id] = Date() }
            },
            videoPreparer: { fileURL in
                exportStartOrder.withLock { $0.append((fileURL, Date())) }
                let current = concurrentExports.withLock { state -> Int in
                    state += 1
                    return state
                }
                maxObservedConcurrentExports.withLock { $0 = max($0, current) }
                try? await Task.sleep(nanoseconds: 40_000_000)
                concurrentExports.withLock { $0 -= 1 }
                return VideoTrimmer.UploadSource(fileURL: fileURL, fileExtension: "mp4", pixelSize: nil)
            }
        )

        let uploads = videoURLs.map { makeVideoUpload(fileURL: $0) }
            + [makePhotoUpload(tag: "a", id: photoID1), makePhotoUpload(tag: "b", id: photoID2)]
        store.enqueue(uploads)

        await waitUntil(timeoutSeconds: 3) { store.remainingCount == 0 }

        XCTAssertEqual(mediaService.uploadPhotoCalls.count, 2, "兩張照片應該都完成，不被影片 export 卡住")
        XCTAssertLessThanOrEqual(
            maxObservedConcurrentExports.withLock { $0 }, 1, "任何時刻同時在跑的 videoPreparer（export）數量不該超過 1"
        )
        let exports = exportStartOrder.withLock { $0 }
        guard exports.count == 3 else {
            return XCTFail("應該有 3 次 videoPreparer 呼叫，實際 \(exports.count)")
        }
        let secondVideoExportStartedAt = exports[1].at
        let photoTimes = photoCompletedAt.withLock { $0 }
        for photoID in [photoID1, photoID2] {
            guard let completedAt = photoTimes[photoID] else {
                return XCTFail("照片 \(photoID) 應該完成")
            }
            XCTAssertLessThan(
                completedAt, secondVideoExportStartedAt, "照片應該在第 2 支影片開始 export 之前就完成，不被前面的影片擋住"
            )
        }
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
