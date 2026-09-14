import AVFoundation
import Foundation

/// 影片裁切／壓縮（LS-125 票文 Scope 3，**LS-279 取消長度門檻**）：發佈前一律用
/// `AVAssetExportSession` 壓到 1080p、只保留前 60 秒再上傳。
///
/// **為什麼不再分流**（LS-279，來源 LS-96 池項 `d8634a08` ＝ LS-125 merge-review R1 I2）：
/// 先前只有「超過 60 秒」才走 export，60 秒內原樣上傳。但 iPhone 4K30 原檔約 170 MB/分，
/// 一支 40 秒的 4K 影片原檔就有 110 MB 左右，必定撞上 Storage 的 50 MiB 單檔上限（413），
/// 而畫面上沒有任何補救路徑——「不做無謂的重新編碼」省下的時間，換來的是一整類短影片
/// 根本傳不上去。現在所有影片都經過同一條 1080p 路徑，短片多花幾秒轉檔，但傳得上去。
///
/// 部署目標 iOS 17：用傳統的 `exportAsynchronously(completionHandler:)` 包成
/// `withCheckedThrowingContinuation`，不是新版 `export() async throws`（那支要 iOS 18+）。
enum VideoTrimmer {
    struct UploadSource {
        let fileURL: URL
        let fileExtension: String
        /// 壓縮後實際輸出的像素尺寸；讀不到輸出檔的視訊軌時是 `nil`，呼叫端沿用草稿原本量到
        /// 的尺寸（merge-review R1 m7：之前一律沿用裁切前尺寸，寫進 `media.width/height`
        /// 的值跟實際上傳的影片對不上）。
        let pixelSize: PixelSize?
    }

    enum TrimmerError: Error {
        case exportSessionUnavailable
        case exportFailed
        case missingFileSize
    }

    /// 壓成 1080p／前 60 秒，回傳真正要拿去上傳的暫存檔。
    ///
    /// `maxByteSize` 預設是 Storage `media` bucket 的單檔上限（`docs/API.md` §6）——export
    /// 完成後先在本機量一次檔案大小，超過就丟 `AppError`（見 `DiaryMediaErrorCode
    /// .videoTooLargeAfterExport`），不把註定拿 413 的檔案送上網路。參數化只為了讓測試能用
    /// 一支短影片覆蓋這條分支，正式路徑不傳。
    static func compressedForUpload(
        fileURL: URL, maxByteSize: Int = MediaUploadLimits.maxObjectByteSize
    ) async throws -> UploadSource {
        let asset = AVURLAsset(url: fileURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw TrimmerError.exportSessionUnavailable
        }
        // LS-212：寫進 `MediaDraftTempStorage` 專屬子目錄，同 `TransferableVideoFile
        // .importing` 的理由（見該檔文件註解）——App 啟動時才能安全地整批清掉孤兒暫存檔。
        let outputURL = try MediaDraftTempStorage.newFileURL(extension: "mp4")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRange(
            start: .zero, duration: await exportDuration(of: asset)
        )
        // LS-283（I1，源自 LS-279 merge-review R1 `5cd2b2ae`）：`withTaskCancellationHandler`
        // 讓取消 Task 真的停下 export——`AVAssetExportSession` 不會自己聽 Swift 的取消信號，
        // 沒有這層包裝的話，使用者取消（或未來任何 `Task.cancel()` 來源）不會讓匯出停止，會
        // 繼續跑完整支並留下沒有回收者的輸出暫存檔。`cancelExport()` 會讓
        // `exportAsynchronously` 的 completion handler以 `.cancelled` 狀態被呼叫，continuation
        // 走下面的 `else` 分支丟錯；這裡額外用 `try?` 直接清掉輸出檔，不依賴呼叫端後續的
        // 清理路徑（那條路徑在丟錯時根本不會被執行到）。`nonisolated(unsafe)`：`cancelExport()`
        // 依 Apple 文件可以從任何執行緒呼叫，這裡只是把已存在的區域變數重新綁定給 `@Sendable`
        // 的 `onCancel` 閉包捕捉，不是引入新的跨執行緒可變狀態。
        nonisolated(unsafe) let cancellableSession = exportSession
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportSession.exportAsynchronously {
                    if exportSession.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: exportSession.error ?? TrimmerError.exportFailed)
                    }
                }
            }
        } onCancel: {
            cancellableSession.cancelExport()
            try? FileManager.default.removeItem(at: outputURL)
        }
        try await checkWithinSizeLimit(outputURL, maxByteSize: maxByteSize)
        let outputPixelSize = await pixelSize(ofFirstVideoTrackIn: AVURLAsset(url: outputURL))
        return UploadSource(fileURL: outputURL, fileExtension: "mp4", pixelSize: outputPixelSize)
    }

    /// 匯出要保留的長度＝「來源長度與 60 秒上限取小的那個」。
    ///
    /// **為什麼要夾**（LS-279 模擬器實測）：`timeRange` 直接寫死 60 秒時，一支 30 秒的來源
    /// 匯出後的檔案長度是 **60 秒**（後半段是靜止畫面），`media.duration_seconds` 也跟著寫成
    /// 60，而且多出來的那 30 秒照樣佔位元組——實測一支 40 秒的 4K 影片因此被撐過 50 MiB 上限
    /// 而遭退回。LS-125 不會踩到：那時只有「超過 60 秒」的影片才會走到 export，`timeRange`
    /// 永遠短於來源。讀不到來源長度（`.duration` 失敗／非數值）時退回 60 秒上限，行為與
    /// 修這條之前一致。
    private static func exportDuration(of asset: AVAsset) async -> CMTime {
        let cap = CMTime(seconds: DiaryDurationFormat.maxPublishDuration, preferredTimescale: 600)
        guard let assetDuration = try? await asset.load(.duration), assetDuration.isNumeric else { return cap }
        return min(assetDuration, cap)
    }

    /// 壓完仍超過單檔上限（極高位元率的長片）：丟一個畫面看得懂的錯誤，並先清掉這份沒人會用
    /// 的輸出暫存檔——呼叫端的 `cleanupVideoTempFiles` 只在成功路徑上跑得到，這裡不清就是
    /// 一個沒有回收者的孤兒檔（LS-279）。
    ///
    /// 丟 `AppError`（不是 `TrimmerError`）跟 `SupabaseMediaUploadService.mapUploadError` 把
    /// Storage 413 映射成 `AppError` 是同一個慣例：這是使用者要看懂、要能自己處置的失敗，
    /// 不是內部技術錯誤；`message` 只供 log／除錯，畫面上的字由
    /// `DiaryPublishErrorMessage.displayText(for:)` 依 `code` 決定（`AppError.swift` 檔頭契約）。
    private static func checkWithinSizeLimit(_ url: URL, maxByteSize: Int) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteSize = attributes[.size] as? Int else { throw TrimmerError.missingFileSize }
        guard byteSize > maxByteSize else { return }
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let suggested = suggestedSeconds(forByteSize: byteSize, duration: seconds, maxByteSize: maxByteSize)
        try? FileManager.default.removeItem(at: url)
        throw AppError.validationRetryable(
            message: "1080p 壓縮後仍有 \(byteSize) bytes／\(seconds) 秒，超過單檔 \(maxByteSize) bytes 上限",
            code: DiaryMediaErrorCode.videoTooLargeAfterExport(suggestedSeconds: suggested)
        )
    }

    /// 「這支影片裁到幾秒才塞得進上限」——用它自己壓完的平均位元率（`byteSize / duration`）
    /// 回推，再乘 0.9 留餘裕（重新裁切後的那一段位元率不會跟整支一模一樣，估太滿會讓使用者
    /// 照著裁完還是失敗）。刻意不用全域常數：1080p 匯出的位元率隨畫面內容差一個數量級
    /// （LS-279 實測 2.4–47.9 Mbps），寫死的秒數對一半的影片都是錯的——本票在模擬器上就撞到
    /// 「40 秒的影片被要求裁到 40 秒內」。時長讀不到（0）時退回
    /// `MediaUploadLimits.suggestedVideoSeconds`；下限 5 秒，不給出「裁到 0 秒」這種廢話。
    static func suggestedSeconds(forByteSize byteSize: Int, duration: Double, maxByteSize: Int) -> Int {
        guard duration > 0, byteSize > 0 else { return MediaUploadLimits.suggestedVideoSeconds }
        return max(5, Int(duration * Double(maxByteSize) / Double(byteSize) * 0.9))
    }

    /// 影片第一條視訊軌「已套用旋轉」後的實際像素尺寸——`naturalSize` 本身不含裝置拍攝方向，
    /// 直向拍的影片要疊上 `preferredTransform` 才會得到直向的寬高（同 `PickedItemLoader` 選片
    /// 當下量的邏輯，抽成共用函式避免兩處各自實作一次同樣的旋轉數學）。讀不到軌道／屬性時
    /// 回傳 `nil`，呼叫端各自決定 fallback。
    static func pixelSize(ofFirstVideoTrackIn asset: AVAsset) async -> PixelSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return PixelSize(width: Int(abs(orientedRect.width)), height: Int(abs(orientedRect.height)))
    }
}
