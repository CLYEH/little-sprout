import XCTest

/// R1 merge-review m4（orchestrator 裁決 `d55ff9ac` 第 6 條，沿 LS-312 M2 既有語彙）：01 讀取
/// 失敗（例如離線）時 `growthStore.records` 也是空的，使用者仍可能已經按過「查看全部紀錄」
/// 進到 03——不能顯示「還沒有紀錄」的空狀態文案（那是「這個孩子真的還沒量過」的語意，跟
/// 「讀取失敗」是兩件不同的事）。
///
/// 沒有 ViewInspector 測不到 `@ViewBuilder` 分支邏輯（同 `GrowthInitialLoadingStateRegression
/// Tests` 文件註解點名的既有理由），這裡用原始碼文字守衛：mutation 把這條分支拿掉（例如
/// `growthStore.records.isEmpty` 一律落回 `emptyState`），這支測試會抓到。
final class GrowthRecordsFailureStateRegressionTests: XCTestCase {
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

    /// mutation：把 `body` 的 `if case .failure = growthStore.loadState { failureState } else {
    /// emptyState }` 拿掉，一律落回 `emptyState`，這支測試轉紅——讀取失敗時會誤顯示「還沒有
    /// 紀錄」。
    func test_body_showsFailureStateWhenLoadFailed_notEmptyStateCopy() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthRecordsListView.swift")

        XCTAssertTrue(
            source.contains(
                "if case .failure = growthStore.loadState {\n"
                    + "                    failureState\n"
                    + "                } else {\n"
                    + "                    emptyState\n"
                    + "                }"
            ),
            "records 為空時要先判斷 loadState 是不是 .failure，是的話顯示 failureState（錯誤文案＋"
                + "「重新載入」），不能一律落回 emptyState 的「還沒有紀錄」文案"
        )
    }

    /// mutation：把 `failureState` 的「重新載入」按鈕拿掉（或改成不呼叫 `refresh()`），這支
    /// 測試轉紅——失敗態必須能重試，不是死路。
    func test_failureState_retryButtonCallsRefresh() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthRecordsListView.swift")

        XCTAssertTrue(
            source.contains("Task { await growthStore.refresh() }"),
            "failureState 的「重新載入」按鈕要呼叫 growthStore.refresh()"
        )
    }
}
