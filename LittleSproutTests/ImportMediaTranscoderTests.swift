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

        let result = ImportMediaTranscoder.convertHEICToJPEG(heicData)

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

            let jpegData = try XCTUnwrap(ImportMediaTranscoder.convertHEICToJPEG(heicData))

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

    /// LS-416：iPhone HEIC 是 Display P3——轉檔改走 ImageIO（中間位圖 8-bit P3，不再經
    /// `UIGraphicsImageRenderer` 的 16-bit extended sRGB 位圖）後，輸出 JPEG 仍要標 Display P3
    /// （不得被裁成 sRGB），且直拍（orientation 6）的畫素要轉對方向：來源儲存畫素左上角的紅色
    /// 區塊，順時針轉 90° 顯示後應在輸出的右上角（只比寬高對調抓不到轉反 180° 的錯）。
    func test_convertHEICToJPEG_displayP3Orientation6_outputKeepsP3AndRotatesClockwise() throws {
        let heicData = try Self.makeDisplayP3HEICWithRedTopLeft(pixelWidth: 40, pixelHeight: 30, exifOrientation: 6)

        // 中間位圖＝記憶體峰值的來源：8-bit P3，不是 `UIGraphicsImageRenderer` 對 P3 來源自動選的
        // 16-bit extended sRGB（每像素多一倍）。只看輸出 JPEG 分不出兩條路徑——兩者都標 Display P3。
        let upright = try XCTUnwrap(ImportMediaTranscoder.uprightImage(fromHEIC: heicData))
        XCTAssertEqual(upright.bitsPerComponent, 8, "中間位圖應為 8-bit（16-bit 會讓 48MP 單張多配 186MB）")
        XCTAssertEqual(upright.colorSpace?.name, CGColorSpace.displayP3, "中間位圖應沿用來源 Display P3")

        let jpegData = try XCTUnwrap(ImportMediaTranscoder.convertHEICToJPEG(heicData))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpegData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3", "輸出 JPEG 應保留 Display P3 色域")
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.displayP3, "輸出畫素色彩空間應為 Display P3")
        XCTAssertEqual([output.width, output.height], [30, 40], "orientation 6：畫素應已轉正（寬高對調）")
        guard [output.width, output.height] == [30, 40] else { return } // 尺寸錯時下方座標會越界
        let pixels = try Self.sRGBPixels(of: output)
        let topRight = pixels(25, 5)
        let bottomLeft = pixels(5, 35)
        XCTAssertTrue(topRight.red > 200 && topRight.green < 80, "orientation 6：來源左上紅塊應轉到輸出右上，實得 \(topRight)")
        XCTAssertTrue(bottomLeft.green > 200 && bottomLeft.red < 80, "輸出左下應為綠色，實得 \(bottomLeft)")
    }

    /// LS-416：Display P3 色彩空間的 HEIC——左上四分之一純紅、其餘 P3 純綠（超出 sRGB 色域）。
    private static func makeDisplayP3HEICWithRedTopLeft(
        pixelWidth: Int, pixelHeight: Int, exifOrientation: Int
    ) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [0, 1, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // CGContext 原點在左下：y 取上半段＝影像的頂端列。
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: pixelHeight / 2, width: pixelWidth / 2, height: pixelHeight / 2))
        let cgImage = try XCTUnwrap(context.makeImage())
        let mutableData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(mutableData, UTType.heic.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: exifOrientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "測試前置：寫出 HEIC 位元組失敗")
        return mutableData as Data
    }

    /// 把影像畫進 8-bit sRGB 位圖，回傳「(column, row)（左上原點）→ 紅、綠通道」查表。
    private static func sRGBPixels(of image: CGImage) throws -> (Int, Int) -> (red: UInt8, green: UInt8) {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let bytes = Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4))
        let width = image.width
        return { column, row in
            let offset = (row * width + column) * 4
            return (bytes[offset], bytes[offset + 1])
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
