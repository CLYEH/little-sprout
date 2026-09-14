import AVFoundation
@testable import LittleSprout
import XCTest

/// `VideoTrimmer.compressedForUpload` 對**真的資產**的行為（LS-279）——這兩條是本票的核心
/// 驗收，刻意不用 stub：要證明的正是「不再依時長分流」與「壓完仍超限就丟錯」這兩件事真的
/// 發生在 `AVAssetExportSession` 這條路徑上，用假物件測等於什麼都沒測。
///
/// 測試資產是當場用 `AVAssetWriter` 寫出來的 4K（3840×2160）影片，**每秒一格**：時長由
/// presentation time 決定（30 格 ＝ 30 秒），不是格數——這樣才能在幾秒內生出一支「30 秒的
/// 4K 影片」，不必真的編碼 900 格。壓縮路徑看的是解析度與時長，跟來源的格率無關。
final class VideoTrimmerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LS-279-VideoTrimmerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    /// LS-279 驗收 1：**30 秒（60 秒以內）的 4K 影片也要走 export**。先前 `trimmedIfNeeded`
    /// 在這個長度直接早退、原樣上傳 4K 原檔（約 85 MB），必定撞 Storage 的 50 MiB 上限
    /// （LS-96 池項 `d8634a08` ＝ LS-125 merge-review R1 I2）。把長度門檻加回去，回傳的就會是
    /// 輸入本身、尺寸是 `nil`，下面兩條斷言都會紅。
    func test_compressedForUpload_thirtySecond4KAsset_stillExportsTo1080p() async throws {
        let sourceURL = try await makeSyntheticVideo(seconds: 30)

        let result = try await VideoTrimmer.compressedForUpload(fileURL: sourceURL)

        XCTAssertNotEqual(result.fileURL, sourceURL, "60 秒以內的影片也必須壓縮，不能原樣上傳 4K 原檔")
        XCTAssertEqual(result.fileExtension, "mp4")
        XCTAssertEqual(
            result.pixelSize, PixelSize(width: 1920, height: 1080), "壓縮輸出必須是 1080p，寫進 media 的尺寸才對得上"
        )
        let exportedSeconds = try await AVURLAsset(url: result.fileURL).load(.duration).seconds
        XCTAssertEqual(
            exportedSeconds, 30, accuracy: 1.5,
            "輸出長度要跟來源一樣是 30 秒——60 秒的 timeRange 套在比它短的資產上不得把輸出撐到 60 秒"
        )
        try? FileManager.default.removeItem(at: result.fileURL)
    }

    /// LS-279 驗收 2：export 完成後本機量到超過單檔上限 → 丟 `AppError`（`code` ＝
    /// `videoTooLargeAfterExport`）而不是回傳一份註定拿 413 的來源，而且不留下輸出暫存檔。
    /// 用 `maxByteSize` 參數把上限降到 1 KiB 覆蓋這條分支——真要生一支壓完超過 50 MiB 的影片
    /// 得編碼數十秒的高位元率 4K，對單元測試不划算，而判斷式本身是同一行。
    func test_compressedForUpload_exportStillOverSizeLimit_throwsAndLeavesNoTempFile() async throws {
        let sourceURL = try await makeSyntheticVideo(seconds: 3)
        let temporaryFilesBefore = try mediaDraftTempFileCount()

        do {
            let result = try await VideoTrimmer.compressedForUpload(fileURL: sourceURL, maxByteSize: 1024)
            XCTFail("壓縮輸出超過上限時不該回傳可上傳的來源（拿到 \(result.fileURL.lastPathComponent)）")
        } catch let error as AppError {
            guard case .validationRetryable(_, let code) = error else {
                return XCTFail("應該是 validationRetryable，實際是 \(error)")
            }
            guard let seconds = DiaryMediaErrorCode.videoTooLargeSuggestedSeconds(fromCode: code) else {
                return XCTFail("碼要帶得出建議秒數，實際是 \(code ?? "nil")")
            }
            XCTAssertGreaterThan(seconds, 0, "建議秒數要是正數，畫面才顯示得出「請裁到 N 秒內」")
        }

        XCTAssertEqual(
            try mediaDraftTempFileCount(), temporaryFilesBefore, "超限的輸出要自己清掉，否則是沒有回收者的孤兒暫存檔"
        )
    }

    /// LS-283（I1，源自 LS-279 merge-review R1 `5cd2b2ae`）：取消 Task 要讓 export 真的停下、
    /// 不留輸出暫存檔。`Task.sleep` 讓 export 先真的開始跑（`exportAsynchronously` 已被呼叫）
    /// 再取消，驗的是「export 中途取消」這個窗口——`test_compressedForUpload_taskCancelledImmediately
    /// _...` 驗的是另一個窗口（取消早於 export 啟動），兩者合起來才覆蓋 R2 B1 修的那顆鎖。
    func test_compressedForUpload_taskCancelled_cancelsExportAndLeavesNoOutputFile() async throws {
        let sourceURL = try await makeSyntheticVideo(seconds: 10)
        let temporaryFilesBefore = try mediaDraftTempFileCount()

        let task = Task { try await VideoTrimmer.compressedForUpload(fileURL: sourceURL) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = try? await task.value

        XCTAssertNil(result, "Task 被取消後 export 不該完成、不該回傳可上傳的壓縮結果")
        XCTAssertEqual(
            try mediaDraftTempFileCount(), temporaryFilesBefore,
            "取消後輸出暫存檔要清掉，不留沒有回收者的孤兒檔"
        )
    }

    /// LS-283 R2（merge-review R1 B1）：取消落在「進入 `compressedForUpload` 之後、
    /// `exportAsynchronously` 真的被呼叫之前」這個窗口——`AVURLAsset` 建立、`newFileURL`、
    /// `await exportDuration` 都是真的 IO／suspension，reviewer 拿掉上面那條測試的
    /// `Task.sleep` 就實測重現 test host crash（`NSInternalInconsistencyException`：
    /// `cancelExport()` 打在還沒呼叫過 `exportAsynchronously` 的 session 上）。這裡不 sleep、
    /// 建立 Task 後立刻同步呼叫 `cancel()`——Task 尚未被排程執行，取消旗標必定搶在
    /// `exportAsynchronously` 之前生效。修好後應該乾淨丟錯（`CancellationError`），不 crash、
    /// 不留輸出檔。
    func test_compressedForUpload_taskCancelledImmediately_throwsWithoutStartingExportOrCrashing() async throws {
        let sourceURL = try await makeSyntheticVideo(seconds: 10)
        let temporaryFilesBefore = try mediaDraftTempFileCount()

        let task = Task { try await VideoTrimmer.compressedForUpload(fileURL: sourceURL) }
        task.cancel()
        let result = try? await task.value

        XCTAssertNil(result, "建 Task 後立刻取消，export 不該啟動、不該回傳可上傳的壓縮結果")
        XCTAssertEqual(
            try mediaDraftTempFileCount(), temporaryFilesBefore,
            "取消早於 export 啟動時不該留下任何輸出暫存檔"
        )
    }

    /// 建議秒數的算法本身（純函式）：以實際輸出的平均位元率回推、乘 0.9 餘裕。
    /// 本票模擬器實測的那支 65 秒素材壓完是 ~78.6 MB／60 秒 → 建議 36 秒，而不是先前寫死的
    /// 40 秒（寫死的話會出現「40 秒的影片請裁到 40 秒內」這種自相矛盾的回話）。
    func test_suggestedSeconds_scalesWithMeasuredBitrateAndFallsBackWhenDurationUnknown() {
        let limit = MediaUploadLimits.maxObjectByteSize

        XCTAssertEqual(
            VideoTrimmer.suggestedSeconds(forByteSize: 78_615_103, duration: 60, maxByteSize: limit), 36,
            "60 秒壓成 78.6 MB → 50 MiB 大約裝得下 40 秒，打九折餘裕後 36 秒"
        )
        XCTAssertEqual(
            VideoTrimmer.suggestedSeconds(forByteSize: 157_230_206, duration: 60, maxByteSize: limit), 18,
            "同樣長度、兩倍位元率，建議秒數要跟著減半——不能是固定值"
        )
        XCTAssertEqual(
            VideoTrimmer.suggestedSeconds(forByteSize: 78_615_103, duration: 0, maxByteSize: limit),
            MediaUploadLimits.suggestedVideoSeconds, "時長讀不到才退回後備常數"
        )
        XCTAssertEqual(
            VideoTrimmer.suggestedSeconds(forByteSize: 1_000_000_000, duration: 60, maxByteSize: limit), 5,
            "極端位元率也不給「裁到 0 秒」這種廢話，下限 5 秒"
        )
    }

    // MARK: - 測試資產

    private func mediaDraftTempFileCount() throws -> Int {
        let directory = try MediaDraftTempStorage.makeDirectoryIfNeeded()
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }

    /// LS-283（I8，源自 LS-279 merge-review R1 `5cd2b2ae`）：`makeSyntheticVideo` 生測試資產失敗
    /// 時丟這個，不是 `XCTSkip`——`XCTSkip` 會讓呼叫它的兩條核心驗收測試變成 skip 而非紅，CI
    /// 照樣綠，違反 Rule 11「fail loud」。
    private struct SyntheticVideoAssetGenerationFailure: Error {}

    /// 4K、每秒一格、內容是隨格數移動的漸層（記憶體填色，不進 CoreGraphics）——只要是能被
    /// `AVAssetExportSession` 讀進來的真資產就夠，不需要像真實影片那樣的高位元率內容。
    private func makeSyntheticVideo(seconds: Int) async throws -> URL {
        let width = 3840
        let height = 2160
        let outputURL = temporaryDirectory.appendingPathComponent("source-\(seconds)s.mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "測試資產寫不出來：\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else {
                XCTFail("取不到 pixel buffer pool——測試資產生不出來，核心驗收測試不該被靜默 skip")
                throw SyntheticVideoAssetGenerationFailure()
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else {
                XCTFail("取不到 pixel buffer——測試資產生不出來，核心驗收測試不該被靜默 skip")
                throw SyntheticVideoAssetGenerationFailure()
            }
            fill(buffer, height: height, frame: frame)
            XCTAssertTrue(
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 1)),
                "第 \(frame) 格寫入失敗：\(String(describing: writer.error))"
            )
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, "測試資產寫入未完成：\(String(describing: writer.error))")
        return outputURL
    }

    private func fill(_ buffer: CVPixelBuffer, height: Int, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let shade = UInt32((row + frame * 7) % 256)
            var pattern: UInt32 = 0xFF00_0000 | (shade << 16) | (shade << 8) | (255 - shade)
            memset_pattern4(base.advanced(by: row * bytesPerRow), &pattern, bytesPerRow)
        }
    }
}
