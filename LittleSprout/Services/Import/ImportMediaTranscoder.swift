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
    /// 处理旋轉。解碼失敗（來源不是有效影像資料）或編碼失敗都回傳 `nil`——呼叫端把這筆當
    /// 「讀不到」整筆捨棄（同 `LegacyAlbumUploadImportCoordinator.loadPhotoUpload` 既有的
    /// nil-短路慣例）。
    static func convertHEICToJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: jpegQuality)
    }
}
