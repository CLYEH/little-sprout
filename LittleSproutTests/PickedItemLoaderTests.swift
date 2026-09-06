import ImageIO
@testable import LittleSprout
import UIKit
import UniformTypeIdentifiers
import XCTest

/// `PickedItemLoader.isSupportedExtension`——Storage bucket 允許的副檔名白名單判斷（merge-review
/// R2 n5：先前整支 `PickedItemLoader` 因依賴真實 `PhotosPickerItem` 自陳不可單元測試，這個決策點
/// 因此零覆蓋；抽成純函式後在這裡直接覆蓋，跟 `supabase/migrations/20260823030000_storage_policies.sql`
/// 的 `allowed_mime_types` 保持一致）。
final class PickedItemLoaderTests: XCTestCase {
    func test_isSupportedExtension_photo_acceptsAllowedExtensions() {
        for ext in ["jpg", "jpeg", "png", "heic", "heif"] {
            XCTAssertTrue(PickedItemLoader.isSupportedExtension(ext, isVideo: false), "\(ext) 應該被照片白名單接受")
        }
    }

    func test_isSupportedExtension_photo_rejectsVideoExtension() {
        XCTAssertFalse(PickedItemLoader.isSupportedExtension("mp4", isVideo: false))
    }

    func test_isSupportedExtension_photo_rejectsUnknownExtension() {
        XCTAssertFalse(PickedItemLoader.isSupportedExtension("gif", isVideo: false))
    }

    func test_isSupportedExtension_video_acceptsAllowedExtensions() {
        for ext in ["mp4", "mov"] {
            XCTAssertTrue(PickedItemLoader.isSupportedExtension(ext, isVideo: true), "\(ext) 應該被影片白名單接受")
        }
    }

    func test_isSupportedExtension_video_rejectsPhotoExtension() {
        XCTAssertFalse(PickedItemLoader.isSupportedExtension("jpg", isVideo: true))
    }

    /// `load(_:)` 呼叫端在傳進來之前已經 `.lowercased()` 過一次——這裡驗證純函式本身不會
    /// 額外幫忙正規化，避免呼叫端誤以為可以隨便傳大寫進來（比對式是 `Set.contains`，大小寫
    /// 敏感）。
    func test_isSupportedExtension_isCaseSensitive() {
        XCTAssertFalse(PickedItemLoader.isSupportedExtension("JPG", isVideo: false))
    }

    // MARK: - `orientedPixelSize(of:)`——EXIF 直拍方向（LS-212，依 LS-96 `66770dd0`）
    //
    // `UIImage(data:).cgImage.width/height` 讀到的是**儲存方向**（感光元件寫入時的原始畫素
    // 矩陣），EXIF 旋轉只記在 `imageOrientation`——這裡用 `CGImageDestination` 產生真的帶
    // EXIF orientation 6／8 標記的 JPEG bytes，經過 `UIImage(data:)` 解碼後驗證換算函式回傳
    // **顯示方向**（跟 `thumb_width`／`thumb_height` 用 `kCGImageSourceCreateThumbnailWithTransform:
    // true` 產生的方向一致），不是 `cgImage` 的原始儲存方向。

    /// EXIF orientation 6＝"Rotate 90 CW"，`UIImage.imageOrientation` 解出來是 `.right`
    /// ——手機直拿拍照最常見的其中一種寫法。
    func test_orientedPixelSize_exifOrientation6_returnsDisplayOrientationSwapped() throws {
        let data = Self.makeJPEGData(pixelWidth: 40, pixelHeight: 30, exifOrientation: 6)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.imageOrientation, .right, "先確認樣本圖真的解出 EXIF 6 對應的 .right，測試才驗到目標情境")

        let pixelSize = PickedItemLoader.orientedPixelSize(of: image)

        XCTAssertEqual(
            pixelSize, PixelSize(width: 30, height: 40),
            "EXIF 6 直拍照片的顯示尺寸應該是直向 30x40，不是 cgImage 儲存方向的橫向 40x30"
        )
    }

    /// EXIF orientation 8＝"Rotate 90 CCW"，解出來是 `.left`——另一種常見的直拍寫法。
    func test_orientedPixelSize_exifOrientation8_returnsDisplayOrientationSwapped() throws {
        let data = Self.makeJPEGData(pixelWidth: 40, pixelHeight: 30, exifOrientation: 8)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.imageOrientation, .left, "先確認樣本圖真的解出 EXIF 8 對應的 .left，測試才驗到目標情境")

        let pixelSize = PickedItemLoader.orientedPixelSize(of: image)

        XCTAssertEqual(pixelSize, PixelSize(width: 30, height: 40))
    }

    /// 負控：EXIF orientation 1（正常方向，橫向拍攝）不應該被誤swap——回歸測試守住「只有
    /// 90°／270° 旋轉才需要交換寬高」這個判準。
    func test_orientedPixelSize_exifOrientation1_keepsRawDimensions() throws {
        let data = Self.makeJPEGData(pixelWidth: 40, pixelHeight: 30, exifOrientation: 1)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.imageOrientation, .up)

        let pixelSize = PickedItemLoader.orientedPixelSize(of: image)

        XCTAssertEqual(pixelSize, PixelSize(width: 40, height: 30))
    }

    func test_orientedPixelSize_nilCGImage_returnsNil() {
        XCTAssertNil(PickedItemLoader.orientedPixelSize(of: UIImage()))
    }

    /// 產生一張 `pixelWidth × pixelHeight`（儲存方向）的純色 JPEG，並在 EXIF 寫入
    /// `exifOrientation`——`CGImageDestinationAddImage` 的 `kCGImagePropertyOrientation`
    /// 屬性只寫 metadata，不會真的旋轉 `cgImage` 的畫素矩陣，正是這裡要模擬的「儲存方向與
    /// 顯示方向不同」情境。
    private static func makeJPEGData(pixelWidth: Int, pixelHeight: Int, exifOrientation: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelWidth, height: pixelHeight), format: format)
        let rawImage = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        guard let cgImage = rawImage.cgImage else {
            XCTFail("測試前置：渲染純色圖失敗")
            return Data()
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            XCTFail("測試前置：建立 CGImageDestination 失敗")
            return Data()
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("測試前置：寫出帶 EXIF orientation 的 JPEG 失敗")
            return Data()
        }
        return mutableData as Data
    }
}
