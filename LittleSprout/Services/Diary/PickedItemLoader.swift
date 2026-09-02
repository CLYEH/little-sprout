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
        /// Storage bucket 不接受的格式（`docs/API.md` §6：僅 jpg/jpeg/png/heic/heif/mp4/mov）
        /// ——挑選階段就擋掉，不要拖到發佈時才被伺服器用無資訊量的錯誤拒絕
        /// （merge-review R1 m4）。
        case unsupportedFormat
    }

    /// Storage bucket 的 `allowed_mime_types`／路徑 regex 對應的副檔名集合
    /// （`supabase/migrations/20260823030000_storage_policies.sql`），跟後端契約保持一致。
    private static let supportedPhotoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    private static let supportedVideoExtensions: Set<String> = ["mp4", "mov"]

    static func load(_ item: PhotosPickerItem) async -> LoadedItem? {
        let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
        let ext = fileExtension(for: item, fallback: isVideo ? "mp4" : "jpg").lowercased()
        guard isSupportedExtension(ext, isVideo: isVideo) else { return .unsupportedFormat }
        return isVideo ? await loadVideo(item, fileExtension: ext) : await loadPhoto(item, fileExtension: ext)
    }

    /// 副檔名是否落在 Storage bucket 允許的集合內——抽成獨立、跟 `PhotosPickerItem` 脫鉤的
    /// 純函式，才能被單元測試直接覆蓋「哪些格式該被擋」這個決策（merge-review R2 n5：先前
    /// 判斷埋在 `load(_:)` 內部，`PickedItemLoader` 整支檔案因依賴真實 `PhotosPickerItem`
    /// 自陳不可單元測試，連帶讓這個決策點零覆蓋）。`ext` 預期已經是小寫（呼叫端統一在傳進
    /// 來之前 `.lowercased()` 一次）。
    static func isSupportedExtension(_ ext: String, isVideo: Bool) -> Bool {
        let allowed = isVideo ? supportedVideoExtensions : supportedPhotoExtensions
        return allowed.contains(ext)
    }

    private static func loadPhoto(_ item: PhotosPickerItem, fileExtension: String) async -> LoadedItem? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        return .photo(
            data: data, fileExtension: fileExtension,
            pixelSize: PixelSize(width: cgImage.width, height: cgImage.height),
            previewImage: await downsizedThumbnail(for: image)
        )
    }

    private static func loadVideo(_ item: PhotosPickerItem, fileExtension: String) async -> LoadedItem? {
        guard let transferred = try? await item.loadTransferable(type: TransferableVideoFile.self) else { return nil }
        let asset = AVURLAsset(url: transferred.url)
        guard let durationValue = try? await asset.load(.duration),
              let pixelSize = await VideoTrimmer.pixelSize(ofFirstVideoTrackIn: asset) else { return nil }
        return .video(
            fileURL: transferred.url, fileExtension: fileExtension,
            duration: CMTimeGetSeconds(durationValue), pixelSize: pixelSize,
            // merge-review R2 n4／R3 P2：`firstFrame(of:)` 是同步函式，這裡先前多帶了一個
            // `await`（Swift 只警告不報錯，未被 CI 攔到；R3 申報「已修」但實際未落地，本輪
            // 才真的拿掉）。
            previewImage: firstFrame(of: asset)
        )
    }

    /// R1 M4：`previewImage` 只是佇列裡的**縮圖**，不需要全解析度——`byPreparingThumbnail(ofSize:)`
    /// 直接產生下採樣後的點陣，不會先把整張原圖解碼進記憶體再縮小（那正是 20 張 4K 原圖同時
    /// 撐爆記憶體的成因）。失敗時退回原圖，至少縮圖還看得到內容。
    private static func downsizedThumbnail(for image: UIImage) async -> UIImage? {
        let target = CGSize(
            width: DiaryPhotoQueueLayout.thumbnailPixelBudget, height: DiaryPhotoQueueLayout.thumbnailPixelBudget
        )
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }

    /// 同上，影片首幀縮圖直接請 `AVAssetImageGenerator` 用 `maximumSize` 下採樣產生，不要生
    /// 全尺寸首幀再自己縮。
    private static func firstFrame(of asset: AVAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: DiaryPhotoQueueLayout.thumbnailPixelBudget, height: DiaryPhotoQueueLayout.thumbnailPixelBudget
        )
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
