import Foundation
@testable import LittleSprout
import XCTest

/// LS-315 R3（merge-review R2 M1）：時間軸入口原本一路沿用 `.importBatchFlow` 的預設參數，
/// 等於永遠拿到 `NoOpImportUploadCoordinator()`——LS-304 併入 `development` 後，使用者從
/// 時間軸「開始匯入」會停在安靜的死路（04 進度頁永遠卡在「已處理 0/M 張」，見該 finding）。
///
/// `TimelineView.resolveUploadCoordinator(_:)`（`TimelineView+Import.swift`）是這次修法抽出
/// 的純函式：`.importBatchFlow(uploadCoordinator:)` 這個引數本身是 SwiftUI 修飾詞參數，這個
/// codebase 沒有 ViewInspector（`git grep ViewInspector` 零結果），無法對「`body` 真的把
/// `importUploadCoordinator` 這個 `@State` 傳進 `.importBatchFlow`」這件事本身做執行期斷言
/// ——但「NoOp 只在還沒建立好之前當保底、建立好之後一定要用真的」這條規則本身是可以抽成一個
/// 不依賴 `@State`／View 生命週期的純函式，直接用型別斷言驗證，不必回頭走原始碼字面比對
/// （同 `AlbumsStoreTests.test_refreshIfEmpty_*` 取代原始碼字面守衛的理由）。剩下「`body` 有沒有正確呼叫
/// 這支函式」由模擬器實跑（時間軸 → 匯入 → 開始匯入 → 04 進度頁推進到 05）覆蓋。
final class TimelineImportUploadCoordinatorTests: XCTestCase {
    @MainActor
    private func makeCoordinator() -> AlbumImportUploadCoordinator {
        AlbumImportUploadCoordinator(
            familyID: UUID(), mediaUploadService: StubMediaUploadService(), albumsStore: .preview()
        )
    }

    /// mutation 對照：若 `resolveUploadCoordinator` 改成無條件回傳 `NoOpImportUploadCoordinator()`
    /// （忽略傳入的 `real`），這支測試會轉紅——`resolved` 不再是 `AlbumImportUploadCoordinator`。
    @MainActor
    func test_resolveUploadCoordinator_returnsRealCoordinatorWhenProvided() {
        let real = makeCoordinator()

        let resolved = TimelineView.resolveUploadCoordinator(real)

        XCTAssertTrue(
            resolved is AlbumImportUploadCoordinator,
            "已建立好的 coordinator 存在時，`.importBatchFlow` 應該拿到真正的 AlbumImportUploadCoordinator，不是 NoOp"
        )
        XCTAssertFalse(resolved is NoOpImportUploadCoordinator)
    }

    /// `importUploadCoordinator` 還沒建立好之前（例如 `.task` 尚未跑完那極短的窗口）才允許
    /// 落回 NoOp——這是型別要求的保底，不是恆用的預設。
    @MainActor
    func test_resolveUploadCoordinator_fallsBackToNoOpWhenNil() {
        let resolved = TimelineView.resolveUploadCoordinator(nil)

        XCTAssertTrue(resolved is NoOpImportUploadCoordinator)
    }
}
