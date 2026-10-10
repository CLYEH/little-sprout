@testable import LittleSprout
import XCTest

/// LS-457：裸 URL 的 `.link` run 必須剛好等於 URL 本體，不得延伸吞進後方中文（對三份
/// docs/legal/*.md 全文實測）。
///
/// 背景：Apple `AttributedString(markdown:)` 的 autolink 把裸 URL 延伸到下一個空白為止；中文段落
/// 沒有空白，所以 terms:12 的「（https://…/privacy-policy）拘束。本服務是為家人打造的…」整段被吞進連結，
/// 連結目的也變成含中文的垃圾位址。
///
/// 獨立成 extension 檔：`LegalMarkdownDocumentTests` 本體已逼近 SwiftLint `type_body_length`（250 行）上限。
/// 期望值來源是原始 md 行的 regex（URL 到空白／漢字／全形標點為止），斷言的是 parser 輸出的 run 範圍與
/// link 屬性，所以拿掉實作的 URL pre-pass 會紅。
extension LegalMarkdownDocumentTests {
    func test_realFiles_everyBareURL_linkRunIsExactlyTheURL() throws {
        var failures: [String] = []
        var checkedURLs = 0
        for source in try Self.legalSources() {
            for (offset, line) in source.raw.components(separatedBy: "\n").enumerated() {
                let expected = line.matches(of: Self.bareURLPattern).map { String($0.output) }
                guard !expected.isEmpty else { continue }
                checkedURLs += expected.count
                // `support@sproutday.app` 這類 email 也會被 autolink 成 `mailto:`——那是正確行為、不是本票要斷言的 URL。
                let actual = LegalMarkdownDocument.parseBlocks(line)
                    .flatMap { Self.linkRuns(Self.attributedText($0)) }
                    .filter { !$0.link.hasPrefix("mailto:") }
                let isExact = actual.count == expected.count
                    && zip(actual, expected).allSatisfy { $0.text == $1 && $0.link == $1 }
                if !isExact {
                    failures.append(
                        "\(source.name):\(offset + 1) 期望 link run＝\(expected)｜實際 run＝\(actual.map(\.text))"
                            + " link＝\(actual.map(\.link))"
                    )
                }
            }
        }
        XCTAssertGreaterThan(checkedURLs, 25, "三份文件應有 30+ 個裸 URL；掃描數異常少代表檔案沒讀到")
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) 行裸 URL 的 link run 不等於 URL 本體：\n" + failures.joined(separator: "\n")
        )
    }

    /// 既有 `[text](url)` 不得被 pre-pass 重複包裝：連結文字與目的各維持原樣、只有一個 link run。
    func test_markdownLink_isLeftUntouched() {
        let url = "https://sproutday.app/legal/privacy-policy"
        let blocks = LegalMarkdownDocument.parseBlocks("詳見[隱私權政策](\(url))全文。")
        guard case .paragraph(let text) = blocks.first else { return XCTFail("應為 paragraph") }
        let links = Self.linkRuns(text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.text, "隱私權政策")
        XCTAssertEqual(links.first?.link, url)
    }

    /// URL 內合法字元（`?`、`#`、`%`、`=`、`&`）不得被截斷。
    func test_bareURL_keepsLegalQueryFragmentAndPercentCharacters() {
        let url = "https://example.com/a/b.aspx?flno=12&pcode=B0000001#frag%20x"
        let blocks = LegalMarkdownDocument.parseBlocks("網址：\(url)（備註）後文")
        guard case .paragraph(let text) = blocks.first else { return XCTFail("應為 paragraph") }
        let links = Self.linkRuns(text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.text, url)
        XCTAssertEqual(links.first?.link, url)
    }

    private static var bareURLPattern: Regex<Substring> { /https?:\/\/[^\s\p{Han}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}]+/ }

    private static func linkRuns(_ text: AttributedString) -> [(text: String, link: String)] {
        text.runs.compactMap { run in
            run.link.map { (String(text[run.range].characters), $0.absoluteString) }
        }
    }
}
