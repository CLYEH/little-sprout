@testable import LittleSprout
import XCTest

/// LS-456：`**粗體**` 不得以字面 `*` 漏到畫面（對三份 docs/legal/*.md 全文實測）。
///
/// 獨立成 extension 檔：`LegalMarkdownDocumentTests` 本體已逼近 SwiftLint `type_body_length`（250 行）上限。
///
/// 為什麼逐行＋全文兩層：`AttributedString(markdown:)` 的 CommonMark flanking 規則對 CJK／全形標點的判定
/// 與 Apple 實作可能不同，所以不猜，直接對每個含 `**` 的來源行單獨走切塊＋inline 解析，失敗訊息帶「檔:行」
/// 與原文片段；全文層再補一個「任何區塊都不得殘留 `*`」，抓跨行段落。
extension LegalMarkdownDocumentTests {
    func test_realFiles_everyBoldSpanSource_rendersWithoutLiteralAsterisksAndHasStrongRun() throws {
        var failures: [String] = []
        var checkedLines = 0
        for source in try Self.legalSources() {
            for (offset, line) in source.raw.components(separatedBy: "\n").enumerated() where line.contains("**") {
                checkedLines += 1
                let texts = LegalMarkdownDocument.parseBlocks(line).map(Self.attributedText)
                let rendered = texts.map { String($0.characters) }.joined(separator: "\n")
                let hasStrongRun = texts.contains { text in
                    text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                }
                let hasAsterisk = rendered.contains("*")
                if hasAsterisk || !hasStrongRun {
                    failures.append(
                        "\(source.name):\(offset + 1) 殘留字面 *=\(hasAsterisk) 有粗體 run=\(hasStrongRun)｜"
                            + String(line.prefix(60))
                    )
                }
            }
        }
        XCTAssertGreaterThan(checkedLines, 60, "三份文件應有 70+ 行含 **；掃描行數異常少代表檔案沒讀到")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 行 ** 粗體未正確渲染：\n" + failures.joined(separator: "\n"))
    }

    func test_realFiles_wholeDocument_noBlockContainsLiteralAsterisk() throws {
        var failures: [String] = []
        for source in try Self.legalSources() {
            let document = LegalMarkdownDocument(rawMarkdown: source.raw)
            for block in document.blocks {
                let text = String(Self.attributedText(block).characters)
                if text.contains("*") { failures.append("\(source.name)｜" + String(text.prefix(60))) }
            }
        }
        XCTAssertTrue(failures.isEmpty, "區塊殘留字面 *：\n" + failures.joined(separator: "\n"))
    }

    /// 兩份進 bundle 的文件讀 bundle 內副本（證明出貨檔案本身過關）；EULA 附加條款不進 bundle
    /// （`project.yml` 只列兩檔），以 `#filePath` 回推 repo 根讀 `docs/legal/eula-addendum.md`。
    static func legalSources(file: StaticString = #filePath) throws -> [(name: String, raw: String)] {
        var sources: [(name: String, raw: String)] = []
        for name in ["terms-of-service", "privacy-policy"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "md"), "\(name).md 不在 bundle")
            sources.append(("\(name).md", try String(contentsOf: url, encoding: .utf8)))
        }
        let repoRoot = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        let eulaURL = repoRoot.appendingPathComponent("docs/legal/eula-addendum.md")
        sources.append(("eula-addendum.md", try String(contentsOf: eulaURL, encoding: .utf8)))
        return sources
    }

    static func attributedText(_ block: LegalMarkdownBlock) -> AttributedString {
        switch block {
        case .heading(let text), .paragraph(let text), .listItem(let text, _), .tableRow(let text, _): text
        }
    }
}
