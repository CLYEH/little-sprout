@testable import LittleSprout
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
}
