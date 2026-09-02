import AVFoundation
import CoreTransferable
import PhotosUI
// `PhotosPickerItem` 實際定義在 PhotosUI × SwiftUI 的 cross-import overlay 裡，只 `import
// PhotosUI` 找不到這個型別（本機實測：`swiftc -typecheck` 單獨對這支檔案跑，加這行前
// "cannot find type 'PhotosPickerItem' in scope"，加之後乾淨）——即使本檔完全不用任何
// SwiftUI View API，也需要這行才能讓 overlay 生效。
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// `PhotosPickerItem` → 佇列草稿需要的原始資料（bytes／暫存檔＋尺寸＋預覽圖）的轉接層。
/// 刻意獨立於 `DiaryComposerStore`：PhotosUI／AVFoundation 的載入結果無法在單元測試裡構造出
/// 假的 `PhotosPickerItem`，這裡只做「讀出資料」這薄薄一層，`DiaryComposerStore.addPhoto`／
/// `addVideo` 收的是已經讀好的純值，才有辦法在沒有真實照片圖庫的情況下被單元測試覆蓋
/// （見該檔文件註解）。這支檔案本身用模擬器手動驗證，不是單元測試對象。
enum PickedItemLoader {
    enum LoadedItem {
        case photo(data: Data, fileExtension: String, pixelSize: PixelSize, previewImage: UIImage?)
        case video(
            fileURL: URL, fileExtension: String, duration: TimeInterval,
            pixelSize: PixelSize, previewImage: UIImage?
        )
    }

    static func load(_ item: PhotosPickerItem) async -> LoadedItem? {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            return await loadVideo(item)
        }
        return await loadPhoto(item)
    }

    private static func loadPhoto(_ item: PhotosPickerItem) async -> LoadedItem? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        return .photo(
            data: data, fileExtension: fileExtension(for: item, fallback: "jpg"),
            pixelSize: PixelSize(width: cgImage.width, height: cgImage.height), previewImage: image
        )
    }

    private static func loadVideo(_ item: PhotosPickerItem) async -> LoadedItem? {
        guard let transferred = try? await item.loadTransferable(type: TransferableVideoFile.self) else { return nil }
        let asset = AVURLAsset(url: transferred.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let durationValue = try? await asset.load(.duration) else { return nil }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return .video(
            fileURL: transferred.url, fileExtension: fileExtension(for: item, fallback: "mp4"),
            duration: CMTimeGetSeconds(durationValue),
            pixelSize: PixelSize(width: Int(abs(orientedRect.width)), height: Int(abs(orientedRect.height))),
            previewImage: firstFrame(of: asset)
        )
    }

    private static func firstFrame(of asset: AVAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func fileExtension(for item: PhotosPickerItem, fallback: String) -> String {
        guard let type = item.supportedContentTypes.first, let ext = type.preferredFilenameExtension else {
            return fallback
        }
        return ext
    }
}

/// 把 PhotosUI 回傳的影片複製到本機暫存檔——`PhotosPickerItem.loadTransferable` 對
/// `FileRepresentation` 型別會把系統暫存的來源檔複製到一個「這次讀取專屬」的路徑，讀取結束
/// 後系統可能隨時清掉原始來源，因此這裡自己再複製一份到 app 自己的暫存目錄，確保發佈流程
/// 稍後（可能是使用者切到別的畫面又回來重試）還讀得到。
private struct TransferableVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
