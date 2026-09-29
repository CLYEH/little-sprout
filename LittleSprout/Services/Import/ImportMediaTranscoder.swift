import UIKit

/// LS-304（票文範圍 2，C2a 使用者裁決照稿定案）：「HEIC 相片會轉成一般照片」——批次匯入把
/// HEIC／HEIF 原始位元組轉成 JPEG 再交給既有上傳管線（`UploadQueueStore`）。純函式，不依賴
/// `PHAsset`／`PhotosPickerItem`，可以直接用合成的 HEIC bytes 單元測試（同
/// `PickedItemLoaderTests` 用 `CGImageDestinationCreateWithData` 產生測試樣本的既有作法）。
enum ImportMediaTranscoder {
    /// 全尺寸原檔轉檔品質——比縮圖的 0.8（`MediaUploadService.thumbnailJPEGQuality`）稍高，
    /// 原檔是使用者實際看到的相片本體，不是列表縮圖，值得多留一點品質；沒有稿面／票文指定
    /// 精確數值，這裡是工程判斷的保守選擇，非既有常數。
    static let jpegQuality: CGFloat = 0.9

    /// `UIImage(data:)` 解碼時已經把 EXIF orientation 讀進 `imageOrientation`，但
    /// `jpegData(compressionQuality:)` **不會**把方向烤進畫素——它照抄未旋轉的 `cgImage`、把
    /// orientation 寫成 EXIF tag（LS-356 實測：直拍 orientation=6 的 40×30 HEIC 轉出來仍是 40×30
    /// 畫素＋EXIF 6）。任何不讀 EXIF 的下游（縮圖、Storage 圖片轉換、`thumb_width/height`）
    /// 都會看到橫躺的相片，所以這裡先用 `UIGraphicsImageRenderer` 依 `imageOrientation` 重繪成
    /// 顯示方向（`UIImage.draw` 會套用 orientation）再編碼：輸出畫素已轉正、EXIF orientation 歸
    /// 1。編碼失敗回傳 `nil`——呼叫端把這筆當「讀不到」整筆捨棄（同
    /// `LegacyAlbumUploadImportCoordinator.loadPhotoUpload` 既有的 nil-短路慣例）。
    ///
    /// merge-review R1 m4：改收已解好的 `UIImage`（不是原始 `Data`）——呼叫端
    /// （`AlbumImportUploadCoordinator.loadPhotoUpload`）早就用同一份 bytes 解過一次算
    /// `pixelSize`，這裡不需要 `UIImage(data:)` 再解第二次同一張圖。**已知限制（未修）**：
    /// 重繪編碼的輸出不含來源的 EXIF／GPS metadata（永久相簿裡原檔
    /// 的拍攝資訊就此消失，`taken_at` 有另外寫進 DB，不影響功能）——完整修法要換成
    /// `CGImageDestinationCreateWithData`＋`CGImageDestinationAddImageFromSource` 保留
    /// metadata（並把 orientation 歸 1），本輪範圍只做「消除雙重解碼」這一半，見 LS-96 記錄。
    static func convertHEICToJPEG(_ image: UIImage) -> Data? {
        // `scale = 1`、`opaque`：輸出畫素＝`image.size`（已是顯示方向的寬高）、不吃裝置螢幕 scale，
        // 也不多配 alpha 通道（同 `AvatarImageProcessor.squareJPEG` 固定 scale=1 的理由）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return upright.jpegData(compressionQuality: jpegQuality)
    }
}
