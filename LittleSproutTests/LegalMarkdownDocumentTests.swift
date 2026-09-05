@testable import LittleSprout
import XCTest

/// LS-191：`LegalMarkdownDocument` 的檔頭解析（版本／生效日期）與本文區塊切分。
///
/// 為什麼直接對 bundled 的 `docs/legal/*.md` 全文跑測試（不是只測合成 fixture）：
/// `LegalMarkdownDocument.parseBlocks` 是手寫的最小化區塊切分器（不是完整 CommonMark
/// 實作），唯一能保證它不會在真實內容上出錯的方法就是真的餵真實內容進去——這兩份文件的
/// 全文結構（標題層級、清單、表格、blockquote）已用一支雛型腳本逐一核對過，這裡把那次
/// 核對結果釘成回歸測試（見票文「AttributedString(markdown:) 渲染 bundled docs/legal/*.md」）。
final class LegalMarkdownDocumentTests: XCTestCase {
    // MARK: - 檔頭解析：版本／生效日期

    func test_metaLine_missingEffectiveDate_showsUnpublishedFallback() {
        let document = LegalMarkdownDocument(rawMarkdown: Self.fixtureWithPlaceholderDate)
        XCTAssertEqual(document.version, "v0.1（草稿，尚未生效）")
        XCTAssertEqual(document.effectiveDateDisplay, "核可後公布")
        XCTAssertEqual(document.metaLine, "版本 v0.1（草稿，尚未生效） · 生效日期：核可後公布")
    }

    func test_metaLine_presentEffectiveDate_showsRawValue() {
        let document = LegalMarkdownDocument(rawMarkdown: Self.fixtureWithRealDate)
        XCTAssertEqual(document.version, "v1.0")
        XCTAssertEqual(document.effectiveDateDisplay, "2026-10-01")
        XCTAssertEqual(document.metaLine, "版本 v1.0 · 生效日期：2026-10-01")
    }

    func test_headerTable_notIncludedInBody() {
        // 檔頭 metadata table 的兩個 key（「版本」「生效日期」）不該出現在本文區塊裡。
        let document = LegalMarkdownDocument(rawMarkdown: Self.fixtureWithPlaceholderDate)
        for block in document.blocks {
            XCTAssertFalse(plainText(block).contains("生效日期"), "檔頭表格不應混進本文區塊")
        }
    }

    // MARK: - 本文區塊切分（經 init(rawMarkdown:) 完整走過檔頭解析）

    func test_parseBlocks_introQuote_isFirstBodyBlockAsParagraph() {
        // Notes `jaQmb`：表格後方的引言段（blockquote）是本文的一部分，不是檔頭。
        let document = LegalMarkdownDocument(rawMarkdown: Self.fixtureWithPlaceholderDate)
        guard case .paragraph = document.blocks.first else {
            return XCTFail("第一個本文區塊應是引言段落，實際是 \(String(describing: document.blocks.first))")
        }
        XCTAssertEqual(plainText(document.blocks[0]), "請仔細閱讀本條款。")
    }

    func test_parseBlocks_heading_and_paragraph() {
        let document = LegalMarkdownDocument(rawMarkdown: Self.fixtureWithPlaceholderDate)
        guard case .heading = document.blocks[1] else {
            return XCTFail("預期第二個區塊是節標題")
        }
        XCTAssertEqual(plainText(document.blocks[1]), "1. 條款的接受與適用")
        guard case .paragraph = document.blocks[2] else {
            return XCTFail("預期第三個區塊是條款段落")
        }
        XCTAssertTrue(plainText(document.blocks[2]).hasPrefix("1.1 本條款"))
    }

    // MARK: - 本文區塊切分（純字串 fixture，直接呼叫 parseBlocks(_:)）
    //
    // 以下五則直接呼叫 `parseBlocks(_:)`（不經過 `init(rawMarkdown:)`／`splitHeader`）：
    // fixture 本身沒有檔頭 metadata table，`splitHeader` 找不到表格時 `bodyStart` 會停在
    // `lines.count`（本文視為空）——這些測試的目的是本文切分邏輯本身，不需要也不該依賴
    // 檔頭解析先跑過一輪。

    /// 條款編號「1.1 文字」不是 markdown 清單語法，應維持單一段落；真正的清單語法「1. 文字」
    /// （數字後面直接接空白，不是另一個數字）才拆成 `.listItem`。這是本檔切分器唯一容易混淆
    /// 的兩種語法，兩者都要在同一份 fixture 裡出現才算真的測到區分邏輯。

    func test_orderedListSyntax_vsClauseNumbering_areDistinguished() {
        let blocks = LegalMarkdownDocument.parseBlocks(Self.fixtureWithOrderedListAndClauseNumbers)
        let kinds = blocks.map(blockKindLabel)
        XCTAssertEqual(
            kinds,
            ["heading", "paragraph", "paragraph", "listItem", "listItem"],
            "6.1 / 6.2 是條款編號（段落），底下的 1. / 2. 才是真正的清單項目"
        )
        XCTAssertEqual(plainText(blocks[1]), "6.1 條款編號不是清單。")
        XCTAssertEqual(plainText(blocks[2]), "6.2 另一段條款編號。")
        XCTAssertEqual(plainText(blocks[3]), "第一個清單項目")
        XCTAssertEqual(plainText(blocks[4]), "第二個清單項目")
    }

    func test_unorderedListSyntax_becomesListItems() {
        let blocks = LegalMarkdownDocument.parseBlocks(Self.fixtureWithUnorderedList)
        let kinds = blocks.map(blockKindLabel)
        XCTAssertEqual(kinds, ["paragraph", "listItem", "listItem"])
        XCTAssertEqual(plainText(blocks[1]), "只把邀請碼交給您信任的人；")
        XCTAssertEqual(plainText(blocks[2]), "發現邀請碼外流時，立即撤銷。")
    }

    func test_tableRows_firstRowIsHeader_separatorRowSkipped() {
        let blocks = LegalMarkdownDocument.parseBlocks(Self.fixtureWithTable)
        let tableBlocks = blocks.compactMap { block -> (String, Bool)? in
            if case .tableRow(let text, let isHeader) = block { return (String(text.characters), isHeader) }
            return nil
        }
        XCTAssertEqual(tableBlocks.count, 2, "分隔列（|---|---|）不應出現在區塊清單裡")
        XCTAssertEqual(tableBlocks[0].0, "資料 · 內容")
        XCTAssertTrue(tableBlocks[0].1, "第一列（表頭）應標記 isHeader")
        XCTAssertEqual(tableBlocks[1].0, "電子郵件地址 · 登入身分識別")
        XCTAssertFalse(tableBlocks[1].1, "資料列不應標記 isHeader")
    }

    func test_inlineBoldMarkup_isPreservedAsAttributedString() {
        let blocks = LegalMarkdownDocument.parseBlocks(Self.fixtureWithBoldText)
        guard case .paragraph(let text) = blocks[0] else {
            return XCTFail("預期第一個區塊是段落")
        }
        let hasBoldRun = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBoldRun, "**不是備份服務** 應解析成粗體 run，不是連 ** 字面一起顯示")
        XCTAssertFalse(String(text.characters).contains("**"), "inline 解析後不應殘留 ** 字面")
    }

    func test_blankLinesAndThematicBreak_doNotProduceEmptyBlocks() {
        let blocks = LegalMarkdownDocument.parseBlocks(Self.fixtureWithBlankLinesAndBreak)
        XCTAssertEqual(blocks.count, 2, "空白行與 --- 分隔線不應產生空區塊")
    }

    // MARK: - 真實 bundled 檔案：載入＋解析全文不噴錯（票文「markdown 載入」驗收）

    func test_loadBundled_termsOfService_parsesRealFileWithoutError() throws {
        let document = try XCTUnwrap(
            LegalMarkdownDocument.loadBundled(.termsOfService),
            "docs/legal/terms-of-service.md 應已透過 project.yml resources 進 app bundle"
        )
        XCTAssertFalse(document.blocks.isEmpty)
        // 草稿期現況（LS-132 文本核可、填入真正生效日期前）：這兩個斷言預期會隨 LS-132
        // 一起更新，不是意外回歸——見票文「不做：法務文本修訂」，日期字串就是從檔案動態讀出。
        XCTAssertEqual(document.version, "v0.1（草稿，尚未生效）")
        XCTAssertEqual(document.effectiveDateDisplay, "核可後公布")
    }

    func test_loadBundled_privacyPolicy_parsesRealFileWithoutError() throws {
        let document = try XCTUnwrap(
            LegalMarkdownDocument.loadBundled(.privacyPolicy),
            "docs/legal/privacy-policy.md 應已透過 project.yml resources 進 app bundle"
        )
        XCTAssertFalse(document.blocks.isEmpty)
        XCTAssertEqual(document.version, "v0.1（草稿，尚未生效）")
        XCTAssertEqual(document.effectiveDateDisplay, "核可後公布")
    }

    /// 兩份文件的 Doc Title 是固定字串（Notes `jaQmb` 對照表），不是讀自檔案的 H1。
    func test_kindTitle_isFixedString_notReadFromFile() {
        XCTAssertEqual(LegalDocumentKind.termsOfService.title, "使用條款")
        XCTAssertEqual(LegalDocumentKind.privacyPolicy.title, "隱私權政策")
    }

    func test_loadBundled_missingResource_returnsNilInsteadOfCrashing() {
        // 沒有這兩個 .md 檔的 bundle（XCTest 框架本身的 bundle）——驗證「檔案不存在」走
        // 優雅的 nil 回傳路徑，不是強制解包炸掉。
        let emptyBundle = Bundle(for: XCTestCase.self)
        XCTAssertNil(LegalMarkdownDocument.loadBundled(.termsOfService, bundle: emptyBundle))
    }

    // MARK: - Helpers

    private func plainText(_ block: LegalMarkdownBlock) -> String {
        switch block {
        case .heading(let text), .paragraph(let text), .listItem(let text): String(text.characters)
        case .tableRow(let text, _): String(text.characters)
        }
    }

    private func blockKindLabel(_ block: LegalMarkdownBlock) -> String {
        switch block {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .listItem: "listItem"
        case .tableRow: "tableRow"
        }
    }

    // MARK: - Fixtures（結構逐一比照 `docs/legal/*.md` 真實檔頭與內文語法）

    private static func fixtureHeader(version: String, effectiveDate: String) -> String {
        """
        # 萌芽日記 Little Sprout 使用條款

        > **草稿（DRAFT）——尚未生效。** 內部提醒文字，不應出現在本文區塊裡。

        | 項目 | 內容 |
        |---|---|
        | 版本 | \(version) |
        | 生效日期 | \(effectiveDate) |
        | 最後修訂 | 2026-09-03（草稿） |

        """
    }

    private static let fixtureWithPlaceholderDate =
        fixtureHeader(version: "v0.1（草稿，尚未生效）", effectiveDate: "[[EFFECTIVE_DATE]]") + """
        > 請仔細閱讀本條款。

        ## 1. 條款的接受與適用

        1.1 本條款是您與本服務營運者之間具有法律效力的協議。
        """

    private static let fixtureWithRealDate =
        fixtureHeader(version: "v1.0", effectiveDate: "2026-10-01") + """
        > 引言段。
        """

    private static let fixtureWithOrderedListAndClauseNumbers = """
    ## 6. 對冒犯性內容零容忍

    6.1 條款編號不是清單。

    6.2 另一段條款編號。

    1. 第一個清單項目
    2. 第二個清單項目
    """

    private static let fixtureWithUnorderedList = """
    4.3 邀請碼有有效期限。您同意：

    - 只把邀請碼交給您信任的人；
    - 發現邀請碼外流時，立即撤銷。
    """

    private static let fixtureWithTable = """
    ### 2.1 帳號資料

    | 資料 | 內容 |
    |---|---|
    | 電子郵件地址 | 登入身分識別 |
    """

    private static let fixtureWithBoldText = """
    2.2 本服務**不是備份服務**。請自行保留原始檔案。
    """

    private static let fixtureWithBlankLinesAndBreak = """


    第一段。


    ---

    第二段。


    """
}
