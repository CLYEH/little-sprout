import XCTest

/// R2 merge-review R2-m1（orchestrator 裁決 `8036a6f0`）：`GrowthRecordsListView.rowItems` 是
/// private computed var，沒有 ViewInspector 測不到（同 `GrowthDetailTitleRegressionTests`
/// 文件註解點名的既有理由）——這裡用原始碼文字守衛確認呼叫點沒有改回整筆同日去重的
/// `GrowthCurve.historyRecords`（R1 M2 的舊 bug：同一天先存身高、再存體重，第二筆會把第一筆
/// 藏起來）。排序邏輯本身的行為測試見 `GrowthCurveTests.test_allRecordsNewestFirst_*`。
final class GrowthRecordsRowOrderRegressionTests: XCTestCase {
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

    /// mutation：把 `rowItems` 的 `for record in GrowthCurve.allRecordsNewestFirst(growthStore.
    /// records)` 改回 `for record in GrowthCurve.historyRecords(growthStore.records)`，這支測試
    /// 轉紅。
    func test_rowItems_usesAllRecordsNewestFirst_notHistoryRecords() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/GrowthRecordsListView.swift")

        XCTAssertTrue(
            source.contains("GrowthCurve.allRecordsNewestFirst(growthStore.records)"),
            "rowItems 要呼叫不去重的 allRecordsNewestFirst，同一天多筆才會全列"
        )
        XCTAssertFalse(
            source.contains("GrowthCurve.historyRecords(growthStore.records)"),
            "rowItems 不能改回整筆去重的 historyRecords（R1 M2 的舊 bug：同日第二筆會把第一筆藏起來）"
        )
    }
}
