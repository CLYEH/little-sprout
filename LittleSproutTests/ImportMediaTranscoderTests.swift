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
