@testable import LittleSprout
import XCTest

/// LS-459：法務 markdown 解析邊界（裸 URL 尾端標點、粗體 pre-pass 的負面案、粗體 run 範圍）。
///
/// 期望值全部手寫成表格（來源片段 → 預期 runs），**不 import／複製實作的 regex**——`+Links`／`+Bold` 的
/// 實檔測試是拿同一個 regex 算期望值（自驗自），實作漂移時兩邊一起漂、測試不會紅。這支用獨立口徑：
/// 預期表 + 實檔 `**…**` 以純字串 split 取得來源片段，不借用實作的任何樣式。
///
/// 獨立成 extension 檔：`LegalMarkdownDocumentTests` 本體已逼近 SwiftLint `type_body_length`（250 行）上限。
extension LegalMarkdownDocumentTests {
    /// 一段預期 run：文字、是否粗體、link 目的（nil＝非連結）。相鄰且屬性相同的 run 會被
    /// `AttributedString` 合併，所以預期表也寫成合併後的形狀。
    private struct ExpectedRun: Equatable, CustomStringConvertible {
        let text: String
        var bold = false
        var code = false
        var link: String?

        var description: String {
            "「\(text)」" + (bold ? "[粗]" : "") + (code ? "[code]" : "") + (link.map { "[→\($0)]" } ?? "")
        }
    }

    private static func run(
        _ text: String, bold: Bool = false, code: Bool = false, link: String? = nil
    ) -> ExpectedRun {
        ExpectedRun(text: text, bold: bold, code: code, link: link)
    }

    private static func actualRuns(_ source: String) -> [ExpectedRun] {
        LegalMarkdownDocument.parseBlocks(source).flatMap { block -> [ExpectedRun] in
            let text = attributedText(block)
            return text.runs.map { run in
                ExpectedRun(
                    text: String(text[run.range].characters),
                    bold: run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true,
                    code: run.inlinePresentationIntent?.contains(.code) == true,
                    link: run.link?.absoluteString
                )
            }
        }
    }

    // MARK: - 裸 URL 尾端標點（GFM autolink：`.,;:!?` 與不成對的 `)` 不入連結）

    func test_edges_bareURL_trailingPunctuationAndParentheses() {
        let url = "https://a.com/x"
        let table: [(source: String, expected: [ExpectedRun])] = [
            ("(see https://a.com/x)", [Self.run("(see "), Self.run(url, link: url), Self.run(")")]),
            ("see https://a.com/x.", [Self.run("see "), Self.run(url, link: url), Self.run(".")]),
            ("see https://a.com/x,", [Self.run("see "), Self.run(url, link: url), Self.run(",")]),
            ("see https://a.com/x;", [Self.run("see "), Self.run(url, link: url), Self.run(";")]),
            ("see https://a.com/x:", [Self.run("see "), Self.run(url, link: url), Self.run(":")]),
            ("see https://a.com/x!", [Self.run("see "), Self.run(url, link: url), Self.run("!")]),
            ("see https://a.com/x?", [Self.run("see "), Self.run(url, link: url), Self.run("?")]),
            ("see https://a.com/x.)", [Self.run("see "), Self.run(url, link: url), Self.run(".)")]),
            // 成對括號在 URL 內：`)` 保留；最外層多出來的 `)` 仍不入連結。
            ("https://a.com/x_(y)", [Self.run("https://a.com/x_(y)", link: "https://a.com/x_(y)")]),
            (
                "(see https://a.com/x_(y))",
                [Self.run("(see "), Self.run("https://a.com/x_(y)", link: "https://a.com/x_(y)"), Self.run(")")]
            ),
            // `?`／`#`／`=`／`&` 在 URL 中間是合法字元，不截。
            (
                "https://a.com/p?q=1&r=2#f.",
                [Self.run("https://a.com/p?q=1&r=2#f", link: "https://a.com/p?q=1&r=2#f"), Self.run(".")]
            )
        ]
        for (source, expected) in table {
            XCTAssertEqual(Self.actualRuns(source), expected, "來源：\(source)")
        }
    }

    // MARK: - 粗體 pre-pass 邊界

    func test_edges_boldPrePass_positiveAndNegativeCases() {
        let url = "https://a.com/x"
        let table: [(source: String, expected: [ExpectedRun])] = [
            ("**a** 與 **b**", [Self.run("a", bold: true), Self.run(" 與 "), Self.run("b", bold: true)]),
            // 未閉合：維持字面，不得吃掉後文、不得出現粗體。
            ("前文 **未閉合 後文", [Self.run("前文 **未閉合 後文")]),
            // URL 緊接粗體：連結止於 URL 本體，粗體獨立成 run。
            ("see " + url + "**粗**", [Self.run("see "), Self.run(url, link: url), Self.run("粗", bold: true)]),
            ("（" + url + "）**粗**", [Self.run("（"), Self.run(url, link: url), Self.run("）"), Self.run("粗", bold: true)]),
            // 粗體內含 URL＋尾端標點：連結仍不含 `.`。
            (
                "**see " + url + ".**",
                [Self.run("see ", bold: true), Self.run(url, bold: true, link: url), Self.run(".", bold: true)]
            ),
            // code span 內的 `**` 是字面：不得變粗體、不得被吃掉。
            ("`**not bold**`", [Self.run("**not bold**", code: true)]),
            (
                "前 `**x**` 後 **y**",
                [Self.run("前 "), Self.run("**x**", code: true), Self.run(" 後 "), Self.run("y", bold: true)]
            ),
            // 連結文字內的 `**`：pre-pass 不切，交 Apple parser——連結完整、沒有殘留 `[` `](` `*`。
            // Apple parser 本身會丟掉連結文字內的強調（實測 `[**粗**](url)` 只剩 link），所以預期是非粗體連結。
            ("[**粗**](https://a.com)", [Self.run("粗", link: "https://a.com")])
        ]
        for (source, expected) in table {
            XCTAssertEqual(Self.actualRuns(source), expected, "來源：\(source)")
        }
    }

    /// `***x***` 交 parser 原生處理（粗斜體）：不得殘留字面 `*`，且為粗體。
    func test_edges_tripleAsterisk_rendersBoldWithoutLiteralAsterisks() {
        let actual = Self.actualRuns("***x***")
        XCTAssertEqual(actual.map(\.text).joined(), "x", "不得殘留字面 *；實際 \(actual)")
        XCTAssertTrue(actual.allSatisfy(\.bold), "應為粗體；實際 \(actual)")
    }

    // MARK: - 實檔：每個 `**…**` 的粗體 run 範圍＝來源片段（逐字相等）

    /// 來源片段用純字串 `components(separatedBy: "**")` 取得（奇數位為粗體內文）；實際值是
    /// parser 輸出裡「連續粗體 run」串起來的字串。`+Bold` 只驗「沒有字面 *」「有粗體 run」，
    /// 範圍錯誤（例如 privacy-policy.md:174 曾有 CJK flanking 導致粗體少吃／多吃）看不出來。
    func test_realFiles_everyBoldSpan_boldRunsEqualSourceSpansVerbatim() throws {
        var failures: [String] = []
        var checkedSpans = 0
        for source in try Self.legalSources() {
            for (offset, line) in source.raw.components(separatedBy: "\n").enumerated() where line.contains("**") {
                let pieces = line.components(separatedBy: "**")
                guard pieces.count % 2 == 1 else {
                    failures.append("\(source.name):\(offset + 1) `**` 個數為奇數，來源本身未閉合｜" + String(line.prefix(60)))
                    continue
                }
                let expectedSpans = stride(from: 1, to: pieces.count, by: 2).map { pieces[$0] }
                checkedSpans += expectedSpans.count
                var actualSpans: [String] = []
                var previousWasBold = false
                for run in Self.actualRuns(line) {
                    if run.bold {
                        if previousWasBold {
                            actualSpans[actualSpans.count - 1] += run.text
                        } else {
                            actualSpans.append(run.text)
                        }
                    }
                    previousWasBold = run.bold
                }
                if actualSpans != expectedSpans {
                    failures.append(
                        "\(source.name):\(offset + 1) 期望粗體 \(expectedSpans)｜實際粗體 \(actualSpans)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(checkedSpans, 60, "三份文件應有 70+ 個粗體片段；掃描數異常少代表檔案沒讀到")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 行粗體範圍≠來源片段：\n" + failures.joined(separator: "\n"))
    }
}
