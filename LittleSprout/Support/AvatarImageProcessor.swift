import ImageIO
import UIKit

/// 寶貝大頭照的中心裁方＋縮圖工具（LS-169）：把 `PhotosPicker` 選出的原始影像位元組裁成
/// 正方形、縮到 512×512、輸出 JPEG。
///
/// 沿用 `MediaUploadService.makePhotoPendingThumbnail` 同一套 `CGImageSource`／
/// `CGImageSourceCreateThumbnailAtIndex` 作法（不像 `UIImage(data:)` 那樣得先把整張原圖解碼
/// 進記憶體），但那支既有工具只縮放、不裁正方形（票文 Scope 1 要求「中心裁方→512×512
/// JPEG」，既有工具的輸出保留長寬比，不符合頭像圓形顯示的需求）——這裡另外一支，不是重寫
/// 既有工具，是它沒有的裁方步驟。
///
/// 呼叫端要自己在背景 `Task` 呼叫（票文「不在主執行緒解碼」）：這是一支同步的純函式，
/// 沒有內建任何執行緒調度，呼叫端負責不要在 `@MainActor` context 直接呼叫它。
enum AvatarImageProcessor {
    /// 產生正方形 JPEG：① 用 `CGImageSourceCreateThumbnailAtIndex` 把原圖降採樣到
    /// `maxPixelSize * 2` 的工作尺寸（避免對超大原圖做全尺寸解碼，同時留足夠解析度給裁切）
    /// ② 以短邊為準置中裁成正方形 ③ 再降採樣一次到 `maxPixelSize × maxPixelSize` ④ 輸出
    /// JPEG。來源資料看不懂（`CGImageSourceCreateWithData` 失敗）或裁切／編碼任一步失敗都
    /// 回傳 `nil`——呼叫端把它當「這張圖片沒辦法處理」的使用者可見錯誤，不是靜默略過。
    static func squareJPEG(from data: Data, maxPixelSize: Int = 512, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * 2,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        let side = min(decoded.width, decoded.height)
        guard side > 0 else { return nil }
        let originX = (decoded.width - side) / 2
        let originY = (decoded.height - side) / 2
        guard let cropped = decoded.cropping(to: CGRect(x: originX, y: originY, width: side, height: side)) else {
            return nil
        }
        let targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // `scale = 1`：不設的話 `UIGraphicsImageRenderer` 預設吃裝置螢幕 scale（模擬器上
        // 常見 3x），畫出來的實際像素會變成 `maxPixelSize * scale`（例如 512 變 1536）——
        // `maxPixelSize` 是 Storage／CHECK 約束在意的「實際像素寬高」，不是「point」，這裡
        // 強制 1:1 對應（同 `SupabaseMediaUploadServiceThumbnailTests.makeTestPhotoJPEGData`
        // 測試輔助函式固定 `scale = 1` 的理由，見該檔）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
