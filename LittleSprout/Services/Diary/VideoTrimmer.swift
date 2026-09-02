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
    }

    enum TrimmerError: Error {
        case exportSessionUnavailable
        case exportFailed
    }

    static func trimmedIfNeeded(
        fileURL: URL, fileExtension: String, duration: TimeInterval
    ) async throws -> UploadSource {
        guard DiaryDurationFormat.exceedsMaxPublishDuration(duration) else {
            return UploadSource(fileURL: fileURL, fileExtension: fileExtension)
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
        return UploadSource(fileURL: outputURL, fileExtension: "mp4")
    }
}
