import Foundation

/// 一個可捲動內文區塊。LS-133 Notes 只要求區分「節標題」與「正文」（`w7eBc`/`PpgKA`）——這裡
/// 額外拆出 `listItem`／`tableRow` 是因為 `docs/legal/*.md` 全文（不是稿面示範用的節錄）本身
/// 就含有序／無序清單與資料表格（例如隱私權政策「2.1 帳號資料」表），不拆開會讓整段清單或
/// 表格擠成一行看不出結構。
enum LegalMarkdownBlock: Equatable {
    case heading(AttributedString)
    case paragraph(AttributedString)
    /// `marker`：無序清單固定 `"•"`；有序清單保留原文字面編號（例如 `"1."`）——merge-review
    /// R1 F1（`807855dc`）：條款交叉引用（如 ToS 6.1「尤其是第 6.1 條第 1 款」）依賴清單編號，
    /// 原本一律丟給 `•` 會讓讀者在 App 內看不到「第 1 款」對應哪一列。
    case listItem(AttributedString, marker: String)
    case tableRow(AttributedString, isHeader: Bool)
}

/// 從 bundled markdown 動態解析出的法務文件：檔頭「版本」「生效日期」兩欄 + 本文區塊清單。
///
/// **不做**（LS-191 票文「不做」段）：不修訂法務文本、不做 `[[OPERATOR_NAME]]` 之類
/// placeholder 的顯示替換——原文是什麼就顯示什麼，草稿期占位字樣待 LS-132 文本核可後隨檔案
/// 內容更新自動生效，不在這裡動手腳。
struct LegalMarkdownDocument: Equatable {
    static let unpublishedDateDisplay = "核可後公布"

    let version: String
    let effectiveDateDisplay: String
    let blocks: [LegalMarkdownBlock]

    /// Head 版本列（`w7eBc`／`WnmNm`：「版本 X · 生效日期：Y」，無日期時 Y 顯示「核可後公布」）。
    var metaLine: String {
        "版本 \(version) · 生效日期：\(effectiveDateDisplay)"
    }

    init(rawMarkdown: String) {
        let header = Self.splitHeader(rawMarkdown)
        self.version = header.version
        self.effectiveDateDisplay = header.effectiveDateRaw.hasPrefix("[[")
            ? Self.unpublishedDateDisplay
            : header.effectiveDateRaw
        self.blocks = Self.parseBlocks(header.body)
    }

    /// 讀 app bundle 內的 markdown 檔並解析。找不到檔案時回傳 nil（呼叫端顯示錯誤狀態，
    /// 不崩潰——這是使用者可能碰到的執行期畫面，不是開發期斷言）。
    static func loadBundled(_ kind: LegalDocumentKind, bundle: Bundle = .main) -> LegalMarkdownDocument? {
        guard let url = bundle.url(forResource: kind.bundleResourceName, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return LegalMarkdownDocument(rawMarkdown: raw)
    }

    // MARK: - 檔頭解析（「版本」「生效日期」兩欄的 markdown table）

    /// SwiftLint `large_tuple`（>2 members）——`splitHeader` 需要回傳三個值，改用具名
    /// struct 取代 tuple。
    private struct ParsedHeader {
        let version: String
        let effectiveDateRaw: String
        let body: String
    }

    /// 把檔頭 metadata table（`| 項目 | 內容 |` ... 那張表）跟本文分開：本文從該表**之後**
    /// 的第一行開始（含 H1 標題與草稿警語 blockquote 之間、以及表格後方的引言段——引言段
    /// 依 LS-133 Notes `jaQmb` 是本文的一部分，不是檔頭）。
    private static func splitHeader(_ raw: String) -> ParsedHeader {
        let lines = raw.components(separatedBy: "\n")
        var version = ""
        var effectiveDateRaw = ""
        var inTable = false
        var bodyStart = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                inTable = true
                if let value = tableCellValue(trimmed, label: "版本") { version = value }
                if let value = tableCellValue(trimmed, label: "生效日期") { effectiveDateRaw = value }
            } else if inTable {
                bodyStart = index
                break
            }
        }
        let body = lines[bodyStart...].joined(separator: "\n")
        return ParsedHeader(version: version, effectiveDateRaw: effectiveDateRaw, body: body)
    }

    /// `| 版本 | v0.1（草稿，尚未生效） |` → label="版本" 回傳 "v0.1（草稿，尚未生效）"。
    private static func tableCellValue(_ line: String, label: String) -> String? {
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return nil }
        let cells = tableCells(line)
        guard cells.count >= 2, cells[0] == label else { return nil }
        return cells[1]
    }

    // MARK: - 本文區塊解析

    /// 逐行掃描本文 markdown，拆成 `LegalMarkdownBlock` 陣列。這是手寫的最小化 markdown
    /// 區塊切分器，不是完整 CommonMark 實作——`docs/legal/*.md` 只用到標題（`#`~`###`）、
    /// 段落、清單（`- `／`1. `）、表格、blockquote（`> `）與分隔線（`---`）五種區塊語法
    /// （已用 `docs/legal/*.md` 全文逐一核對，見 LittleSproutTests），多的語法不支援。
    /// 每個區塊內部的粗體／連結交給 `AttributedString(markdown:)` 做 inline 解析
    /// （已先剝掉區塊語法字元，inline 解析器不會再被 `#`／`|`／`-` 這些字元混淆）。
    static func parseBlocks(_ body: String) -> [LegalMarkdownBlock] {
        var blocks: [LegalMarkdownBlock] = []
        var pendingLines: [String] = []

        func flushParagraph() {
            guard !pendingLines.isEmpty else { return }
            let text = pendingLines.joined(separator: " ")
            pendingLines.removeAll()
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            blocks.append(.paragraph(inlineAttributed(text)))
        }

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" || line == "***" || line == "___" {
                flushParagraph()
                continue
            }
            if let headingText = headingText(line) {
                flushParagraph()
                blocks.append(.heading(inlineAttributed(headingText)))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                var quoted = String(line.dropFirst())
                if quoted.hasPrefix(" ") { quoted.removeFirst() }
                blocks.append(.paragraph(inlineAttributed(quoted)))
                continue
            }
            if let (marker, text) = orderedListItemText(line) {
                flushParagraph()
                blocks.append(.listItem(inlineAttributed(text), marker: marker))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.listItem(inlineAttributed(String(line.dropFirst(2))), marker: "•"))
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                appendTableRow(line, to: &blocks)
                continue
            }
            pendingLines.append(line)
        }
        flushParagraph()
        return blocks
    }

    /// merge-review R1 N2：多欄表格（例如隱私權政策「2.1 帳號資料」四欄表）原本把整列 cell
    /// 用 `" · "` 接成一行，AX3 下會變成很長一串、欄位語意只能靠順序推。改成每個 cell 各自
    /// 一行（`"\n"` 分隔，`Text` 原生支援換行）——不需要表頭標籤對照就能大幅改善長列可讀性；
    /// 「哪個 cell 對應哪個表頭欄位」這種完整標籤化留待後續（記入 LS-96），本輪只做這個
    /// 零風險的分行改善。
    private static func appendTableRow(_ line: String, to blocks: inout [LegalMarkdownBlock]) {
        guard !isTableSeparatorRow(line) else { return }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return }
        let isHeaderRow: Bool
        if case .tableRow = blocks.last { isHeaderRow = false } else { isHeaderRow = true }
        blocks.append(.tableRow(inlineAttributed(cells.joined(separator: "\n")), isHeader: isHeaderRow))
    }

    /// `## 標題文字` → "標題文字"（任意層級 `#`~`######`，本專案只出現到 `###`，見 Notes
    /// 「節標題」——單一樣式不分層級，見 `LegalDocumentSheet`）。
    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == " " else { return nil }
        return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    /// `1. 文字` → `(marker: "1.", text: "文字")`；刻意跟條款編號「1.1 文字」區分——後者數字
    /// 後面接的是另一個數字而非空白，不會落入這個判斷（見 LittleSproutTests 的兩則對照案例）。
    /// **保留 `marker` 原字面**（merge-review R1 F1，`807855dc`）：法務文本的交叉引用（例如
    /// ToS「尤其是第 6.1 條第 1 款」）依賴清單編號，只給文字、丟掉編號會讓讀者對不到「第幾款」。
    private static func orderedListItemText(_ line: String) -> (marker: String, text: String)? {
        var index = line.startIndex
        var sawDigit = false
        while index < line.endIndex, line[index].isNumber {
            sawDigit = true
            index = line.index(after: index)
        }
        guard sawDigit, index < line.endIndex, line[index] == "." else { return nil }
        let marker = String(line[line.startIndex...index])
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (marker, text)
    }

    /// `|---|:--:|` 這種只由 `-`／`:`／`|`／空白組成的表格分隔列，本身不是資料、跳過不渲染。
    /// 多欄表格中間還有 `|`（例如 `|---|---|` 的中間那個），用
    /// `.replacingOccurrences` 整段拿掉所有 `|` 再檢查——原本用 `trimmingCharacters` 只從
    /// 頭尾各修掉一個字元，中間的 `|` 沒被拿掉，`allSatisfy` 因此對多欄表格永遠回傳
    /// `false`（LittleSproutTests 抓到，實測 `|---|---|` 中間那個 `|` 讓分隔列被誤判成
    /// 資料列渲染成 `--- · ---`）。
    private static func isTableSeparatorRow(_ line: String) -> Bool {
        let inner = line.replacingOccurrences(of: "|", with: "")
        return !inner.isEmpty && inner.allSatisfy { "-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 已剝掉區塊語法字元的單行/單段文字，交給系統 inline markdown 解析器處理粗體／連結。
    /// **必須明確指定 `interpretedSyntax: .inlineOnlyPreservingWhitespace`**——
    /// `AttributedString(markdown:)` 不帶 `options` 時的預設值其實是 `.full`（實測驗證，
    /// 不是文件字面暗示的「純 inline」），對「1. 條款的接受與適用」這種本身就長得像合法
    /// 單項清單的節標題文字，會把 `1. ` 這個清單標記當結構吃掉、只留下「條款的接受與適用」
    /// ——LittleSproutTests 抓到這個回歸（全部節標題數字消失），已改用明確的 inline-only
    /// 選項修正：同樣的字面文字現在保證原樣保留，只處理粗體／連結。
    /// 解析失敗（理論上不會，見 LittleSproutTests 對全文兩份文件的覆蓋測試）時退回純文字，
    /// 不讓一個排版問題讓整份文件開不了。
    private static func inlineAttributed(_ text: String) -> AttributedString {
        // LS-456 pre-pass：先把 `**…**` 切成獨立的粗體 run，其餘文字各自交給 `parseInline`。
        // 原因（對 `docs/legal/*.md` 實測）：裸 URL（`（https://…）`）後 Apple parser 會把 URL autolink
        // 延伸到下一個空白為止，連同後面的 `**…**` 一起吞進連結 URL，字面 `**` 漏到畫面（terms:12）。
        // 先切開，`**` 就不會落在任何 autolink 範圍內，也不依賴 Apple 對 CJK flanking 的判定。
        var result = AttributedString()
        var cursor = text.startIndex
        while let open = nextBoldDelimiter(in: text, from: cursor),
              let close = nextBoldDelimiter(in: text, from: text.index(open, offsetBy: 2)) {
            if cursor < open { result += parseInline(String(text[cursor..<open])) }
            var bold = parseInline(String(text[text.index(open, offsetBy: 2)..<close]))
            for run in Array(bold.runs) {
                let existing = bold[run.range].inlinePresentationIntent ?? []
                bold[run.range].inlinePresentationIntent = existing.union(.stronglyEmphasized)
            }
            result += bold
            cursor = text.index(close, offsetBy: 2)
        }
        if cursor < text.endIndex { result += parseInline(String(text[cursor...])) }
        return result
    }

    /// 從 `start` 起找下一個「恰好兩個 `*`」的粗體分隔符，回傳其起點；找不到回 nil（未閉合 `**` 因此維持字面）。
    /// 掃描時整段跳過 code span（`` `…` ``）與 `[文字](網址)`——裡面的 `**` 不是這一層的分隔符，留給
    /// `parseInline` 的 Apple parser 原生處理（`[**粗**](url)` 變成粗體連結、`` `**x**` `` 保持字面）。
    /// 連續 3 個以上的 `*`（`***x***`）整串跳過，同樣交給 Apple parser（粗斜體），不在這裡硬切出殘留的字面 `*`。
    private static func nextBoldDelimiter(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if let span = text[index...].prefixMatch(of: /`[^`]+`|\[[^\]]*\]\([^)]*\)/) {
                index = span.range.upperBound
            } else if text[index] == "*" {
                var runEnd = index
                while runEnd < text.endIndex, text[runEnd] == "*" { runEnd = text.index(after: runEnd) }
                if text.distance(from: index, to: runEnd) == 2 { return index }
                index = runEnd
            } else {
                index = text.index(after: index)
            }
        }
        return nil
    }

    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let wrapped = wrapBareURLs(text)
        return (try? AttributedString(markdown: wrapped, options: options)) ?? AttributedString(text)
    }

    /// LS-457 pre-pass：把裸 URL 包成 `<url>`（CommonMark autolink），讓連結範圍＝URL 本體。
    /// 原因（對 `docs/legal/*.md` 實測）：Apple parser 的裸 URL autolink 延伸到下一個空白，中文段落沒有空白，
    /// 於是 terms:12 的「（https://…）拘束。本服務是為家人打造的」整段被吞進連結（藍字＋連結目的含中文垃圾位址）。
    /// URL 到空白、漢字（`\p{Han}`）、全形標點（`U+3000–303F`、`U+FF00–FFEF`，含 `）`）為止；ASCII 的
    /// `?`／`#`／`%`／`=`／`&` 都是 URL 合法字元，不截。已是 `[text](url)`、`[url](…)`、`<url>` 的不重複包裝
    /// （前一字元是 `[`／`<`，或前兩字元是 `](`）。
    private static func wrapBareURLs(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in text.matches(of: /https?:\/\/[^\s\p{Han}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}]+/) {
            let start = match.range.lowerBound
            let before = text[..<start]
            if before.last == "[" || before.last == "<" || before.hasSuffix("](") { continue }
            let url = trimTrailingPunctuation(match.output)
            result += text[cursor..<start]
            result += "<\(url)>"
            cursor = url.endIndex
        }
        result += text[cursor...]
        return result
    }

    /// GFM autolink 尾端規則：`.,;:!?` 不入連結；`)` 只有在 URL 內 `(` 與 `)` 成對時才保留
    /// （`https://a.com/x_(y)` 整段是連結；`(see https://a.com/x)` 的 `)` 不是）。回傳的是原字串的前綴切片。
    private static func trimTrailingPunctuation(_ url: Substring) -> Substring {
        var end = url.endIndex
        while end > url.startIndex {
            let last = url[url.index(before: end)]
            if ".,;:!?".contains(last) {
                end = url.index(before: end)
            } else if last == ")", url[..<end].filter({ $0 == ")" }).count > url[..<end].filter({ $0 == "(" }).count {
                end = url.index(before: end)
            } else {
                break
            }
        }
        return url[..<end]
    }
}
