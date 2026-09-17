import XCTest

/// LS-312 R2（merge-review R1 m1，orchestrator 裁決 `824c4aba`）：寶貝詳情
/// （`ChildGrowthDetailView`）是唯讀畫面，所有家庭成員（含 viewer）都該能開——`childRow(_:)`
/// 不該再用 `canManageChildren` 擋掉 viewer 的 `NavigationLink`。這是「原始碼文字」規則守衛
/// （同 `ImportBatchFlowModifierRegressionTests` 文件註解點名的既有理由，這個 codebase 沒有
/// ViewInspector，無法在單元測試裡對 SwiftUI View 的分支邏輯直接內省）：可機械重放（改回
/// `if childrenStore.canManageChildren { NavigationLink(...) } else { ... }` → 這裡立刻紅），
/// 但不驗證執行期行為本身（執行期行為由 `TapTargetGateTests.testChildrenManagementViewPopulated`
/// 之類的既有 UI test 覆蓋 owner 路徑不受影響；viewer 路徑因不新增 tap-target 註冊
/// case——`TapTargetGateScreenName.swift` 已頂到 swiftlint `file_length` 400 行上限，見
/// merge-review R1 i4——只用這支源碼守衛＋人工程式碼審閱）。
final class ChildRowNavigationRegressionTests: XCTestCase {
    /// 同 `ImportBatchFlowModifierRegressionTests.sourceText(relativePath:)`：拿掉 `//` 註解列
    /// 再比對，避免文件註解裡剛好提到的字面（例如這次修法的說明）誤判成「程式碼還在」。
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

    /// 抓出 `private func childRow(_ child: Child) -> some View { ... }` 這個函式本體
    /// （抓到下一個 `private func`／`private var` 或檔案結尾的 `}`），不比對到檔案其他部分
    /// （`childDetail(for:)` 的 `editDestination` gate 本來就該保留 `canManageChildren`）。
    private func childRowFunctionBody(_ source: String) throws -> String {
        guard let startRange = source.range(of: "private func childRow(_ child: Child) -> some View {") else {
            throw XCTSkip("找不到 childRow 函式——ChildrenManagementView.swift 結構可能已經改變")
        }
        let afterStart = source[startRange.upperBound...]
        guard let endRange = afterStart.range(of: "\n    private func childRowContent") else {
            throw XCTSkip("找不到 childRow 函式結尾——ChildrenManagementView.swift 結構可能已經改變")
        }
        return String(afterStart[..<endRange.lowerBound])
    }

    /// mutation：把 `childRow(_:)` 改回 `if childrenStore.canManageChildren { NavigationLink
    /// (...) } else { childRowContent(child, showsChevron: false) }`（R1 的舊寫法），這支測試
    /// 應該轉紅——viewer 進不去寶貝詳情頁。
    func test_childRow_doesNotGateNavigationLinkOnCanManageChildren() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Children/ChildrenManagementView.swift")
        let functionBody = try childRowFunctionBody(source)

        XCTAssertFalse(
            functionBody.contains("canManageChildren"),
            "childRow(_:) 不該再用 canManageChildren 擋 NavigationLink——寶貝詳情是唯讀畫面，"
                + "viewer 也該能開（merge-review R1 m1，orchestrator 裁決）"
        )
        XCTAssertTrue(
            functionBody.contains("NavigationLink(value: ChildrenRoute.detail(child.id))"),
            "childRow(_:) 應該無條件建立 NavigationLink(value: ChildrenRoute.detail(child.id))"
        )
    }
}
