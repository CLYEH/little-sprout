import XCTest

/// QA `49c96b88`（FAIL）：`ChildGrowthDetailView.latestValuesRow` 原本從頭到尾是固定
/// `HStack`，AX3（`.accessibility3` 以上）下三格擠在窄欄裡把數字逐字元拆行（例如「78.5」拆成
/// 「7」換行「8」），違反 Notes `a9S6ke`（AX3 板）「Latest Values」節點 `TAbxe` 的
/// `layout: vertical`（對比一般字級板 `jp6ka` 的 `iYQf1` 為橫向）與長輩優先硬約束「0 截字」。
///
/// 沒有 ViewInspector 測不到 `HStack`／`VStack` 實際渲染出的樹（同 `GrowthDetailTitleRegressionTests`
/// 文件註解點名的既有理由），這裡用原始碼文字守衛：mutation 把 AX3 分支拿掉、只留固定
/// `HStack(spacing: AppSpacing.group)`，這支測試會抓到。
final class GrowthLatestValuesAX3RegressionTests: XCTestCase {
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

    /// mutation：把 `latestValuesRow` 的 `if dynamicTypeSize >= .accessibility3 { VStack… }
    /// else { HStack… }` 分支拿掉、改回單一 `HStack(spacing: AppSpacing.group) { … }`——這支測試轉紅。
    func test_latestValuesRow_ax3UsesVerticalStack_belowAX3UsesHorizontalStack() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        guard let rowRange = source.range(of: "private func latestValuesRow(") else {
            XCTFail("找不到 latestValuesRow——檔案結構被改動")
            return
        }
        guard let cardsRange = source.range(of: "private func latestValueCards(") else {
            XCTFail("找不到 latestValueCards——檔案結構被改動")
            return
        }
        let body = String(source[rowRange.lowerBound..<cardsRange.lowerBound])

        XCTAssertTrue(
            body.contains("dynamicTypeSize >= .accessibility3"),
            "latestValuesRow 必須依 dynamicTypeSize 是否達到 .accessibility3 切換版面——"
                + "這是 QA 49c96b88 FAIL 的直接成因（缺這個分支）"
        )
        XCTAssertTrue(
            body.contains("VStack(spacing: AppSpacing.item) { latestValueCards(growthStore) }"),
            "AX3 下三格要上下堆疊（Notes a9S6ke「Latest Values」節點 TAbxe：layout vertical，"
                + "gap $sp-item），不能維持固定 HStack 把數字擠成逐字元換行"
        )
        XCTAssertTrue(
            body.contains("HStack(spacing: AppSpacing.group) { latestValueCards(growthStore) }"),
            "一般字級（低於 .accessibility3）要維持原本橫向排列（Notes jp6ka「Latest Values」"
                + "節點 iYQf1），不能整段改成永遠直式"
        )
    }
}
