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
    func test_convertHEICToJPEG_validHEICData_returnsDecodableJPEGWithSameDimensions() throws {
        let heicData = try Self.makeHEICData(pixelWidth: 40, pixelHeight: 30)

        let result = ImportMediaTranscoder.convertHEICToJPEG(heicData)

        let jpegData = try XCTUnwrap(result, "有效 HEIC 位元組轉檔不該回傳 nil")
        // JPEG 檔頭 magic bytes（0xFFD8）——確認輸出真的是 JPEG，不是原樣回傳的 HEIC。
        XCTAssertEqual(Array(jpegData.prefix(2)), [0xFF, 0xD8])
        let decoded = try XCTUnwrap(UIImage(data: jpegData))
        XCTAssertEqual(decoded.cgImage?.width, 40)
        XCTAssertEqual(decoded.cgImage?.height, 30)
    }

    func test_convertHEICToJPEG_invalidData_returnsNil() {
        XCTAssertNil(ImportMediaTranscoder.convertHEICToJPEG(Data([0x00, 0x01, 0x02])))
    }

    func test_convertHEICToJPEG_emptyData_returnsNil() {
        XCTAssertNil(ImportMediaTranscoder.convertHEICToJPEG(Data()))
    }

    /// 產生一張 `pixelWidth × pixelHeight` 的純色 HEIC 影像位元組——同
    /// `PickedItemLoaderTests.makeJPEGData` 的既有作法，目的格式換成 `.heic`。
    private static func makeHEICData(pixelWidth: Int, pixelHeight: Int) throws -> Data {
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
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "測試前置：寫出 HEIC 位元組失敗")
        return mutableData as Data
    }
}
