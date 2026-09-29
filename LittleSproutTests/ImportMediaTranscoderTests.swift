import ImageIO
@testable import LittleSprout
import UIKit
import UniformTypeIdentifiers
import XCTest

/// LS-304（票文範圍 2，C2a）：「HEIC 相片會轉成一般照片」——`ImportMediaTranscoder
/// .convertHEICToJPEG` 是純函式，用真的 HEIC 編碼位元組驗證（同
/// `PickedItemLoaderTests.makeJPEGData` 用 `CGImageDestinationCreateWithData` 產生測試樣本
/// 的既有作法，這裡換成 `UTType.heic` 目的格式）。
final class ImportMediaTranscoderTests: XCTestCase {
    /// merge-review R1 m4：函式簽章改收已解好的 `UIImage`（不是原始 `Data`）——消除呼叫端
    /// （`AlbumImportUploadCoordinator.loadPhotoUpload`）對同一份 bytes 解碼兩次。「來源
    /// 位元組解不出來」這個失敗分支現在完全在呼叫端的 `UIImage(data:)` 那一行（同檔案
    /// `guard ... let image = UIImage(data: result.data) ... else { return nil }`），不再是
    /// 這支純函式的職責，原本兩支 `invalidData`／`emptyData` 測試因此移除（同函式改簽章一併
    /// 清理，非另外的死碼）。
    func test_convertHEICToJPEG_validHEICImage_returnsDecodableJPEGWithSameDimensions() throws {
        let heicData = try Self.makeHEICData(pixelWidth: 40, pixelHeight: 30)
        let image = try XCTUnwrap(UIImage(data: heicData), "測試前置：解碼合成 HEIC 失敗")

        let result = ImportMediaTranscoder.convertHEICToJPEG(image)

        let jpegData = try XCTUnwrap(result, "有效 HEIC 影像轉檔不該回傳 nil")
        // JPEG 檔頭 magic bytes（0xFFD8）——確認輸出真的是 JPEG，不是原樣回傳的 HEIC。
        XCTAssertEqual(Array(jpegData.prefix(2)), [0xFF, 0xD8])
        let decoded = try XCTUnwrap(UIImage(data: jpegData))
        XCTAssertEqual(decoded.cgImage?.width, 40)
        XCTAssertEqual(decoded.cgImage?.height, 30)
    }

    /// LS-356：iPhone 直拍 HEIC 的儲存方向是橫的（感光元件寫入的 `pixelWidth × pixelHeight`，例如
    /// 4032×3024），方向只靠 EXIF orientation（6＝順時針轉 90°顯示、8＝逆時針）。轉出來的 JPEG
    /// 必須畫素已轉正（寬高對調）且 EXIF orientation 歸 1（或不帶），否則任何忽略 EXIF 的顯示
    /// 端（縮圖產生、`thumb_width/height`、Storage 圖片轉換）都會看到橫躺的相片。
    func test_convertHEICToJPEG_orientation6And8_outputIsUprightWithOrientation1() throws {
        for orientation in [6, 8] {
            let heicData = try Self.makeHEICData(pixelWidth: 40, pixelHeight: 30, exifOrientation: orientation)
            let image = try XCTUnwrap(UIImage(data: heicData), "測試前置：解碼合成 HEIC 失敗")

            let jpegData = try XCTUnwrap(ImportMediaTranscoder.convertHEICToJPEG(image))

            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpegData as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 30, "orientation \(orientation)：畫素寬應已轉正")
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 40, "orientation \(orientation)：畫素高應已轉正")
            let outputOrientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            XCTAssertEqual(outputOrientation, 1, "orientation \(orientation)：輸出 EXIF orientation 應為 1")
        }
    }

    /// 產生一張 `pixelWidth × pixelHeight` 的純色 HEIC 影像位元組——同
    /// `PickedItemLoaderTests.makeJPEGData` 的既有作法，目的格式換成 `.heic`。
    /// `exifOrientation`（LS-356）：寫進 HEIC 的 EXIF orientation（畫素本身不旋轉，同真實直拍檔）。
    private static func makeHEICData(pixelWidth: Int, pixelHeight: Int, exifOrientation: Int? = nil) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelWidth, height: pixelHeight), format: format)
        let rawImage = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        let cgImage = try XCTUnwrap(rawImage.cgImage, "測試前置：渲染純色圖失敗")
        let mutableData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(mutableData, UTType.heic.identifier as CFString, 1, nil),
            "測試前置：建立 HEIC CGImageDestination 失敗（模擬器/主機需支援 HEIC 編碼）"
        )
        let properties = exifOrientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, cgImage, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "測試前置：寫出 HEIC 位元組失敗")
        return mutableData as Data
    }
}
