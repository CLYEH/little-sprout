import ImageIO
@testable import LittleSprout
import UIKit
import XCTest

/// `AvatarImageProcessor.squareJPEG`（LS-169）：中心裁方＋縮到指定像素＋JPEG 編碼。核心風險
/// 是「輸出真的是正方形、真的是要求的尺寸」——這是頭像圓形顯示能不能撐滿、不變形的前提，不是
/// 單純「有輸出就好」。
final class AvatarImageProcessorTests: XCTestCase {
    func test_squareJPEG_wideSource_outputsExactSquareAtMaxPixelSize() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 800, pixelHeight: 400)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 512))
        let size = try Self.decodedPixelSize(of: output)

        XCTAssertEqual(size.width, 512)
        XCTAssertEqual(size.height, 512)
    }

    func test_squareJPEG_tallSource_outputsExactSquareAtMaxPixelSize() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 300, pixelHeight: 900)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 512))
        let size = try Self.decodedPixelSize(of: output)

        XCTAssertEqual(size.width, 512)
        XCTAssertEqual(size.height, 512)
    }

    /// 來源已經是正方形、但比目標尺寸大——仍然要縮到目標尺寸，不是「已經是方的就不處理」。
    func test_squareJPEG_alreadySquareSource_stillResizesToMaxPixelSize() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 2000, pixelHeight: 2000)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 512))
        let size = try Self.decodedPixelSize(of: output)

        XCTAssertEqual(size.width, 512)
        XCTAssertEqual(size.height, 512)
    }

    /// 來源比目標尺寸小——輸出仍然要精確是目標尺寸（`UIGraphicsImageRenderer` 的
    /// `draw(in:)` 一律依目標 rect 繪製，會放大，不會維持原始的小尺寸），這樣頭像圓形容器
    /// 才不會露出背景。
    func test_squareJPEG_smallerThanTarget_stillUpscalesToMaxPixelSize() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 100, pixelHeight: 100)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 512))
        let size = try Self.decodedPixelSize(of: output)

        XCTAssertEqual(size.width, 512)
        XCTAssertEqual(size.height, 512)
    }

    /// `maxPixelSize` 是呼叫端可控參數（不是寫死 512）——這裡驗證真的有生效，不是永遠回傳
    /// 固定的 512。
    func test_squareJPEG_respectsCustomMaxPixelSize() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 800, pixelHeight: 800)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 256))
        let size = try Self.decodedPixelSize(of: output)

        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 256)
    }

    func test_squareJPEG_undecodableData_returnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])

        XCTAssertNil(AvatarImageProcessor.squareJPEG(from: garbage))
    }

    func test_squareJPEG_outputIsValidJPEG() throws {
        let data = Self.makeSolidColorJPEG(pixelWidth: 640, pixelHeight: 480)

        let output = try XCTUnwrap(AvatarImageProcessor.squareJPEG(from: data, maxPixelSize: 512))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertEqual(type, "public.jpeg")
    }

    // MARK: - Helpers

    /// 產生一張 `pixelWidth × pixelHeight` 的純色 JPEG——強制 `scale = 1`，確保回傳的 `Data`
    /// 解碼回來的像素尺寸就是傳進去的參數，同 `SupabaseMediaUploadServiceThumbnailTests` 既有
    /// 慣例（不跨檔重用是因為那支是 `private`，這裡另外一份小型、僅本檔使用的版本）。
    private static func makeSolidColorJPEG(pixelWidth: Int, pixelHeight: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight), format: format
        )
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        return image.jpegData(compressionQuality: 1.0)!
    }

    private static func decodedPixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }
}
