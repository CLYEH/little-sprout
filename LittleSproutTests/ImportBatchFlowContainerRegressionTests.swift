import XCTest

/// merge-review R2 M5：`ImportBatchFlowContainer` 的三條離開路徑（05「完成／回到時間軸」、
/// 04「在背景繼續，關閉視窗」、04b「取消整批」）都要釋放這個批次的縮圖——同
/// `ImportBatchFlowModifierRegressionTests` 檔頭理由：`route` 是 private `@State`，這個
/// codebase 沒有 ViewInspector 可以內省 SwiftUI 閉包內容（`git grep ViewInspector` 零結果），
/// 只能退而求其次鎖住原始碼本身的呼叫次數。這是刻意、透明的取捨：可機械重放（拿掉任一條
/// 路徑的呼叫，這裡立刻紅），但不驗證執行期行為本身（執行期行為由 `UploadQueueStore
/// .releaseThumbnails(for:)` 自己的狀態測試——`UploadQueueStoreReleaseThumbnailsTests`——覆蓋）。
final class ImportBatchFlowContainerRegressionTests: XCTestCase {
    /// 同 `ImportBatchFlowModifierRegressionTests.sourceText`：往上兩層拿到 worktree 根目錄，
    /// 濾掉 `//` 註解列，避免文件註解裡剛好提到的字面誤判成「程式碼還在」。
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

    /// merge-review R2 M5 mutation：拿掉 `onLeaveInBackground`／`onCancelledImport` 任一條的
    /// `store.releaseThumbnails(for: session.entryIDSet)` 呼叫，出現次數就不再是 3，這支測試
    /// 立刻紅（M5 修正前只有 `onDone`＝05「完成」一條，出現次數是 1）。
    func test_allThreeExitPathsReleaseThumbnails() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Import/ImportBatchFlowContainer.swift")
        let occurrences = source.components(separatedBy: "store.releaseThumbnails(for: session.entryIDSet)").count - 1
        XCTAssertEqual(
            occurrences, 3,
            "05「完成」／04「在背景繼續」／04b「取消整批」——三條離開路徑都要呼叫 releaseThumbnails(for:)（merge-review R2 M5）"
        )
    }
}
