import XCTest

/// LS-312 R3（merge-review R2 m1，orchestrator 裁決 `8cf0114c`）：首次載入期間（`.submitting`＋
/// 還沒有任何資料）不能誤呈現成 04「這張紙還沒有記錄」骨架版——冷啟動／慢網時使用者會盯著空
/// 狀態文案，可能直接按「新增量測」，且 `growth_records` 沒有 `unique(child_id, measured_on)`，
/// 2/2 上線後偶發延遲會讓這個誤判更常發生。修法同既有正解 `AlbumDetailView.
/// photoGridOrEmptyState` 的 `case .submitting where store.photos.isEmpty: ProgressView()`。
///
/// 沒有 ViewInspector 測不到 `@ViewBuilder` 分支邏輯（同 `GrowthDetailTitleRegressionTests`
/// 文件註解點名的既有理由），這裡用原始碼文字守衛：mutation 把這條 guard 拿掉，這支測試會抓到。
final class GrowthInitialLoadingStateRegressionTests: XCTestCase {
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

    /// mutation：把 `content(_:)` 的 `if case .submitting = growthStore.loadState,
    /// growthStore.isEmpty { ProgressView() } else { ... }` 拿掉，直接進 `regularLayout`／
    /// `compactLayout`（R1／R2 的舊行為），這支測試轉紅——首次載入會誤呈現成 04 空狀態。
    func test_content_showsProgressViewDuringInitialLoad_notEmptyStateSkeleton() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        XCTAssertTrue(
            source.contains(
                "if case .submitting = growthStore.loadState, growthStore.isEmpty {\n"
                    + "            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)"
            ),
            "content(_:) 應該在首次載入（.submitting 且還沒有資料）時顯示 ProgressView，不能直接落到"
                + "compactLayout／regularLayout 誤渲染成 04 空狀態骨架版"
        )
    }
}
