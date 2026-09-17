import XCTest

/// LS-315 merge-review R2 M2：本檔案是「原始碼文字」規則守衛，不是行為測試——同
/// `ImportBatchFlowModifierRegressionTests` 文件註解點名的既有理由，這個 codebase 沒有
/// ViewInspector 之類能在單元測試裡內省 SwiftUI View 修飾詞（這裡是 Button 的 action
/// closure）內部邏輯的工具（`git grep ViewInspector` 零結果）。時間軸「匯入」入口點擊時
/// 補載相簿清單這段邏輯埋在 `TimelineView.importEntryButton` 的 action closure 裡，一般
/// XCTest 無法對它的執行期行為直接斷言，只能退而求其次鎖住原始碼本身的關鍵字面（可機械
/// 重放：拿掉這段 → 這裡的測試立刻紅；不驗證執行期行為本身，執行期行為由
/// `AlbumsStoreTests` 覆蓋 `AlbumsStore.refresh` 本身的正確性）。
final class TimelineImportAlbumsRegressionTests: XCTestCase {
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

    /// merge-review R2 M2 mutation：把 `if albumsStore.albums.isEmpty ... { Task { await
    /// albumsStore.refresh(familyID: familyID) } }` 這段拿掉，這支測試應該轉紅——冷啟動
    /// 直接停在時間軸（預設 tab）、沒逛過相簿 tab 就點「匯入」，`AlbumsStore.albums` 初值
    /// 空陣列（唯一填值來源 `refresh`／`loadMore` 只有 `AlbumsView` 呼叫），整理頁每群的
    /// 相簿選單會只剩「不放相簿」一個選項。
    func test_importEntryButtonAction_preloadsAlbumsWhenEmpty() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Timeline/TimelineView+Import.swift")
        XCTAssertTrue(
            source.contains("albumsStore.albums.isEmpty"),
            "「匯入」鈕的 action 必須守門檢查 `albumsStore.albums.isEmpty`——" +
                "沒有這個守門，每次點擊都會重打一次相簿清單 RPC（merge-review R2 M2）"
        )
        XCTAssertTrue(
            source.contains("await albumsStore.refresh(familyID: familyID)"),
            "「匯入」鈕的 action 必須在相簿清單為空時補一次 `albumsStore.refresh(familyID:)`——" +
                "沒有這行，時間軸入口進整理頁的相簿選單永遠只有「不放相簿」（merge-review R2 M2）"
        )
    }
}
