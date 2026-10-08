import ImageIO
import UniformTypeIdentifiers

/// LS-304（票文範圍 2，C2a 使用者裁決照稿定案）：「HEIC 相片會轉成一般照片」——批次匯入把
/// HEIC／HEIF 原始位元組轉成 JPEG 再交給既有上傳管線（`UploadQueueStore`）。純函式，不依賴
/// `PHAsset`／`PhotosPickerItem`，可以直接用合成的 HEIC bytes 單元測試（同
/// `PickedItemLoaderTests` 用 `CGImageDestinationCreateWithData` 產生測試樣本的既有作法）。
enum ImportMediaTranscoder {
    /// 全尺寸原檔轉檔品質——比縮圖的 0.8（`MediaUploadService.thumbnailJPEGQuality`）稍高，
    /// 原檔是使用者實際看到的相片本體，不是列表縮圖，值得多留一點品質；沒有稿面／票文指定
    /// 精確數值，這裡是工程判斷的保守選擇，非既有常數。
    static let jpegQuality: CGFloat = 0.9

    /// HEIC 的 EXIF orientation 必須烤進畫素（LS-356：直拍 orientation=6 的 HEIC 若只照抄未旋轉
    /// 畫素＋EXIF tag，任何不讀 EXIF 的下游——縮圖、Storage 圖片轉換、`thumb_width/height`——都會
    /// 看到橫躺的相片）：輸出畫素已轉正、不帶 EXIF orientation（＝1）。編碼失敗回傳 `nil`——
    /// 呼叫端把這筆當「讀不到」整筆捨棄（同 `LegacyAlbumUploadImportCoordinator.loadPhotoUpload`
    /// 既有的 nil-短路慣例）。
    ///
    /// **已知限制（未修，LS-96 記錄）**：輸出不含來源的 EXIF／GPS metadata（`taken_at` 另外寫進
    /// DB，不影響功能）。
    static func convertHEICToJPEG(_ data: Data) -> Data? {
        guard let upright = uprightImage(fromHEIC: data) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, upright, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// LS-416：全尺寸、已轉正的位圖——ImageIO 直接從來源 bytes 解成來源色彩空間（iPhone HEIC＝
    /// 8-bit Display P3）。原本用 `UIGraphicsImageRenderer` 重繪轉正：P3 來源讓 renderer 自動選
    /// extended range，配出 16-bit extended sRGB 位圖（12MP 一張 93MB、48MP 372MB），加上來源
    /// 本身的解碼，模擬器實測 48MP 3 群並行峰值 2.8GB（LS-416 handoff）。這裡的位圖是 8-bit P3
    /// （12MP 46.5MB）；ImageIO 解碼＋轉正時內部仍約佔 2 份位圖，同法實測峰值約減半（1.31GB）。
    ///
    /// - `CreateThumbnailFromImageAlways`：不拿 HEIC 內嵌的小縮圖，一律從主影像解。
    /// - `ThumbnailMaxPixelSize`＝來源長邊：不縮小，輸出仍是原尺寸。
    /// - `CreateThumbnailWithTransform`：依 EXIF orientation 轉正（LS-356）。
    ///
    /// internal（非 private）只為了讓測試直接斷言中間位圖的位深與色彩空間——那就是記憶體峰值的來源。
    static func uprightImage(fromHEIC data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
