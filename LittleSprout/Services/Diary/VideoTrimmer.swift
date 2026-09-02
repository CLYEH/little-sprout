import AVFoundation
import Foundation

/// 影片裁切／壓縮（LS-125 票文 Scope 3）：選到的影片若超過 60 秒，發佈前用
/// `AVAssetExportSession` 裁前 60 秒並壓到 1080p 再上傳；不超過就原樣上傳，不做無謂的
/// 重新編碼（省時間、也不因為轉檔動到不需要動的檔案品質）。
///
/// 部署目標 iOS 17：用傳統的 `exportAsynchronously(completionHandler:)` 包成
/// `withCheckedThrowingContinuation`，不是新版 `export() async throws`（那支要 iOS 18+）。
enum VideoTrimmer {
    struct UploadSource {
        let fileURL: URL
        let fileExtension: String
        /// 裁切／壓縮後實際輸出的像素尺寸；未裁切（≤60 秒原樣上傳）時是 `nil`，呼叫端沿用
        /// 草稿原本量到的尺寸即可——裁切才需要重新量，因為輸出解析度跟輸入不同
        /// （merge-review R1 m7：之前一律沿用裁切前尺寸，寫進 `media.width/height` 的值跟
        /// 實際上傳的影片對不上）。
        let pixelSize: PixelSize?
    }

    enum TrimmerError: Error {
        case exportSessionUnavailable
        case exportFailed
    }

    static func trimmedIfNeeded(
        fileURL: URL, fileExtension: String, duration: TimeInterval
    ) async throws -> UploadSource {
        guard DiaryDurationFormat.exceedsMaxPublishDuration(duration) else {
            return UploadSource(fileURL: fileURL, fileExtension: fileExtension, pixelSize: nil)
        }
        let asset = AVURLAsset(url: fileURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw TrimmerError.exportSessionUnavailable
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: DiaryDurationFormat.maxPublishDuration, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: exportSession.error ?? TrimmerError.exportFailed)
                }
            }
        }
        let outputPixelSize = await pixelSize(ofFirstVideoTrackIn: AVURLAsset(url: outputURL))
        return UploadSource(fileURL: outputURL, fileExtension: "mp4", pixelSize: outputPixelSize)
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
