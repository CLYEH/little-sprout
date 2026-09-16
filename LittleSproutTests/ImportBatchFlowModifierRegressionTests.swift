import XCTest

/// LS-303 R3（merge-review R2 M3）：本檔案兩支測試都是「原始碼文字」規則守衛，不是行為測試
/// ——這個 codebase 沒有 ViewInspector 之類能在單元測試裡內省 SwiftUI View 修飾詞內部參數的
/// 工具（`git grep ViewInspector` 零結果），`.photosPicker(photoLibrary:)` 這個參數、
/// `.onChange` 內是否真的用 `Task.detached` 離開 MainActor，都無法用一般 XCTest 對執行期行為
/// 斷言直接覆蓋，只能退而求其次鎖住原始碼本身的關鍵字面。這是刻意、透明的取捨（見 R3
/// handoff M3 段）：可機械重放（改回舊寫法 → 這裡的測試立刻紅），但不驗證執行期行為本身
/// （執行期行為由 mobile-mcp 實機互動驗證，見 handoff）。
final class ImportBatchFlowModifierRegressionTests: XCTestCase {
    /// `#filePath` 是這支測試檔自己的絕對路徑（`<worktree>/LittleSproutTests/…swift`）——
    /// 往上兩層拿到 worktree 根目錄，再組出目標原始碼的路徑，跨開發者環境不受硬編路徑影響。
    /// 回傳「拿掉 `//` 註解列」之後的原始碼——避免這裡的斷言被文件註解裡剛好提到的同一段
    /// 字面（例如解釋這次修法的 doc comment）誤判為「程式碼還在」而測不出真正的回退（曾在
    /// 本機驗證：拿掉 `photoLibrary: .shared()` 這個真正的呼叫參數，但檔頭 doc comment 裡
    /// 剛好也寫了同一串字面說明這次修法，若不濾掉註解列，測試會維持綠燈量不到回退）。
    private func sourceText(relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(relativePath)
        let fullText = try String(contentsOf: sourceURL, encoding: .utf8)
        return fullText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// merge-review R2 B1 mutation (a)：把 `photoLibrary: .shared()` 拿掉，這支測試應該轉紅
    /// ——Apple SDK 對 `PhotosPickerItem.itemIdentifier` 的 doc string：沒有帶 photo library
    /// 建立的 picker，`itemIdentifier` 一律 nil（真機也是，不是 simulator 限制），會讓整理頁
    /// 「共 0 張・0 個日期群」（見 handoff M3 mutation 段的斷言原文）。
    func test_photosPicker_declaresSharedPhotoLibrary() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Import/ImportBatchFlowModifier.swift")
        XCTAssertTrue(
            source.contains("photoLibrary: .shared()"),
            "`.photosPicker` 必須帶 `photoLibrary: .shared()`——沒有帶的話 itemIdentifier 一律 nil（merge-review R2 B1）"
        )
    }

    /// merge-review R1 M5 mutation (b)：把 `Task.detached(priority: .userInitiated)` 這段拿掉
    /// （改回在 `.onChange` 內同步呼叫 `PhotoLibraryAccessService.fetchResult`），這支測試應該
    /// 轉紅——`fetchResult` 內的 `PHAsset.fetchAssets`／`enumerateObjects` 是同步、會卡住呼叫
    /// 執行緒的 Photos 資料庫查詢，不能留在 MainActor 上跑，否則使用者選 200 張時整理頁開啟前
    /// 主執行緒會卡頓。
    func test_pickerSelectionOnChange_dispatchesPhotoAssetFetchOffMainActor() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Import/ImportBatchFlowModifier.swift")
        XCTAssertTrue(
            source.contains("Task.detached(priority: .userInitiated)"),
            "`.onChange(of: pickerSelection)` 內呼叫 `PhotoLibraryAccessService.fetchResult` 必須包在 "
                + "`Task.detached` 裡——同步 `PHAsset.fetchAssets` 留在 MainActor 會卡住整理頁開啟前的主執行緒（merge-review R1 M5）"
        )
    }
}
