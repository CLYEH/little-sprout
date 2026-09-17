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

    /// `UIImage(data:)` 解碼時已經把 EXIF orientation 讀進 `imageOrientation`（同
    /// `PickedItemLoader.orientedPixelSize` 文件註解的既有事實）；`jpegData(compressionQuality:)`
    /// 重新編碼時會依 `imageOrientation` 把方向烤進畫素矩陣（輸出永遠是「up」），不需要另外
    /// 处理旋轉。編碼失敗回傳 `nil`——呼叫端把這筆當「讀不到」整筆捨棄（同
    /// `LegacyAlbumUploadImportCoordinator.loadPhotoUpload` 既有的 nil-短路慣例）。
    ///
    /// merge-review R1 m4：改收已解好的 `UIImage`（不是原始 `Data`）——呼叫端
    /// （`AlbumImportUploadCoordinator.loadPhotoUpload`）早就用同一份 bytes 解過一次算
    /// `pixelSize`，這裡不需要 `UIImage(data:)` 再解第二次同一張圖。**已知限制（未修）**：
    /// `jpegData(compressionQuality:)` 的輸出不含來源的 EXIF／GPS metadata（永久相簿裡原檔
    /// 的拍攝資訊就此消失，`taken_at` 有另外寫進 DB，不影響功能）——完整修法要換成
    /// `CGImageDestinationCreateWithData`＋`CGImageDestinationAddImageFromSource` 保留
    /// metadata，需要額外處理 orientation（`CGImageDestination` 不像 `UIImage.jpegData`
    /// 那樣自動把 `imageOrientation` 烤進畫素），本輪範圍只做「消除雙重解碼」這一半，見
    /// LS-96 記錄。
    static func convertHEICToJPEG(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }
}
