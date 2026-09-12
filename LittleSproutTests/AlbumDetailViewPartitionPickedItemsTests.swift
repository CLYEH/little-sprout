import Foundation
@testable import LittleSprout
import XCTest

/// LS-237 修（池 `1aa74165` m2）：`AlbumDetailView+Actions.loadPicked` 對不支援格式
/// （`.unsupportedFormat`）與載入失敗（`PickedItemLoader.load` 回 `nil`）原本都靜默
/// `continue`，使用者選 5 張佇列只出現 3 張、無任何回饋。分類邏輯抽成
/// `AlbumDetailView.partitionPickedItems(_:)`（同 `CommentsSheetView.headCommentCountText`
/// 既有慣例：`PhotosPickerItem` 本身無法在單元測試建構假值，但載入完成後怎麼分類是純資料
/// 轉換，見 `PickedItemLoader` 文件註解「無法在單元測試裡構造出假的 PhotosPickerItem」）。
final class AlbumDetailViewPartitionPickedItemsTests: XCTestCase {
    private let pixelSize = PixelSize(width: 100, height: 100)

    /// 票文驗收「2 不支援格式出現回話列」：選 5 張，其中 2 張不支援格式、1 張載入失敗，
    /// 應該只有 2 張進佇列、skippedCount 是 3（兩種原因合計，不分開計）。
    func test_partitionPickedItems_unsupportedFormatAndLoadFailure_bothCountAsSkipped() {
        let loaded: [PickedItemLoader.LoadedItem?] = [
            .photo(data: Data([1]), fileExtension: "jpg", pixelSize: pixelSize, previewImage: nil),
            .unsupportedFormat,
            .video(
                fileURL: URL(fileURLWithPath: "/tmp/a.mov"), fileExtension: "mov", duration: 10,
                pixelSize: pixelSize, previewImage: nil
            ),
            .unsupportedFormat,
            nil
        ]

        let (uploads, skippedCount) = AlbumDetailView.partitionPickedItems(loaded)

        XCTAssertEqual(uploads.count, 2, "5 張裡有 2 張不支援格式、1 張載入失敗，應該只有 2 張進佇列")
        XCTAssertEqual(skippedCount, 3, "不支援格式（2）與載入失敗（1）都算略過，合計 3")
    }

    func test_partitionPickedItems_allSucceed_skippedCountIsZero() {
        let loaded: [PickedItemLoader.LoadedItem?] = [
            .photo(data: Data([1]), fileExtension: "jpg", pixelSize: pixelSize, previewImage: nil),
            .photo(data: Data([2]), fileExtension: "png", pixelSize: pixelSize, previewImage: nil)
        ]

        let (uploads, skippedCount) = AlbumDetailView.partitionPickedItems(loaded)

        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(skippedCount, 0, "全部成功時不該有任何略過")
    }

    func test_partitionPickedItems_allSkipped_uploadsIsEmpty() {
        let loaded: [PickedItemLoader.LoadedItem?] = [.unsupportedFormat, nil, .unsupportedFormat]

        let (uploads, skippedCount) = AlbumDetailView.partitionPickedItems(loaded)

        XCTAssertTrue(uploads.isEmpty, "全部略過時佇列應該是空的（loadPicked 的 guard 不會開出上傳佇列）")
        XCTAssertEqual(skippedCount, 3)
    }
}
