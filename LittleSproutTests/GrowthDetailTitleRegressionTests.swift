import XCTest

/// LS-312 R2（merge-review R1 m2，orchestrator 裁決 `824c4aba`）：Notes `mfafV` 06 那列寫
/// 「標題 自訂（Identity Header 內 Name）」——iPad `regularLayout` 不該再讓系統
/// `.navigationTitle` 重複印一次孩子名字（`identityHeader` 已經印過一次）；01／04（iPhone）
/// 維持系統 large（Notes 那兩列寫「標題 系統 large」，逐字不同，不能一併改）。
///
/// 沒有 ViewInspector 測不到 `.navigationTitle`／`.navigationBarTitleDisplayMode` 這兩個
/// modifier 實際吃到的值（同 `ChildRowNavigationRegressionTests` 文件註解點名的既有理由），
/// 這裡用原始碼文字守衛：mutation 把 06 的條件拿掉、兩個平台都印 `child.name`，這支測試會抓到。
final class GrowthDetailTitleRegressionTests: XCTestCase {
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

    /// mutation：把 `.navigationTitle(horizontalSizeClass == .regular ? "" : child.name)` 改回
    /// `.navigationTitle(child.name)`（06 跟 01/04 用同一顆系統標題）——這支測試轉紅。
    func test_navigationTitle_emptyOnRegularSizeClass_toAvoidDoublingName() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        XCTAssertTrue(
            source.contains(#".navigationTitle(horizontalSizeClass == .regular ? "" : child.name)"#),
            "06（iPad，horizontalSizeClass == .regular）不該再用系統 .navigationTitle 顯示孩子名字——"
                + "identityHeader 已經印過一次（merge-review R1 m2）"
        )
        XCTAssertTrue(
            source.contains(".navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)"),
            "01/04（iPhone）要維持系統 large 標題（Notes mfafV 那兩列逐字寫「標題 系統 large」），"
                + "只有 06 改成 .inline"
        )
    }
}
