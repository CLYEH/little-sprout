import XCTest

/// R1 merge-review m3／i1（orchestrator 裁決 `d55ff9ac` 第 6／7 條）：`ChildGrowthDetailView`
/// 的「新增量測」鈕（compact／regular 各一顆）要依 `canManageChildren` 決定要不要顯示——
/// viewer 按下去必得 `42501`（`upsert_growth_record` 只認 owner／member）；06 的「歷史紀錄」
/// 區塊要有進 03 列表的入口（`GrowthHistorySection` 純顯示，之前完全沒有編輯／刪除路徑）。
///
/// 沒有 ViewInspector 測不到 `@ViewBuilder` 分支邏輯（同 `GrowthDetailTitleRegressionTests`
/// 文件註解點名的既有理由），這裡用原始碼文字守衛。
final class GrowthDetailViewerGatingRegressionTests: XCTestCase {
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

    /// mutation：把 `actionsCompact`／`regularLayout` 任一處的 `if canManageChildren { ... }`
    /// 拿掉（讓「新增量測」一律顯示），這支測試會抓到——`canManageChildren` 這個字面必須在
    /// `ChildGrowthDetailView.swift` 出現至少兩次「`if canManageChildren {`」（compact／regular
    /// 各一次）。
    func test_addMeasurementButton_gatedByCanManageChildren_inBothLayouts() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        let occurrences = source.components(separatedBy: "if canManageChildren {").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "compact（actionsCompact）與 regular（regularLayout）各要有一次 `if canManageChildren`" +
                " 包住「新增量測」鈕，viewer 兩邊都不該看到——實際出現 \(occurrences) 次"
        )
    }

    /// mutation：呼叫端 `childDetail(for:)` 若不再傳 `canManageChildren:
    /// childrenStore.canManageChildren`（例如漏傳、或傳固定 `true`），這支測試會抓到。
    func test_childrenManagementView_passesCanManageChildrenFromStore() throws {
        let source = try sourceText(
            relativePath: "LittleSprout/Features/Children/ChildrenManagementView+Detail.swift"
        )

        XCTAssertTrue(
            source.contains("canManageChildren: childrenStore.canManageChildren"),
            "childDetail(for:) 要把 childrenStore.canManageChildren 轉手給 ChildGrowthDetailView"
        )
    }

    /// mutation：把 06 `regularLayout` 裡「查看全部紀錄」那顆 `NavigationLink` 拿掉，這支測試
    /// 會抓到——原本只有 compact 版一個入口（1 次），i1 之後 06 也要有一個（2 次）。
    func test_regularLayout_hasEntryPointIntoRecordsList() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        let occurrences = source.components(separatedBy: "GrowthRecordsListView(").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "compact（actionsCompact）與 regular（regularLayout，i1 新增）各要有一個進 03 列表的" +
                "入口——實際出現 \(occurrences) 次"
        )
    }
}
