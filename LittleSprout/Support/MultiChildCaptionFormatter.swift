import SwiftUI

/// 日記卡（`cmp/Card Diary` `qtCd7`）署名 caption（LS-126 票文 Scope 3；LS-374 對稿）：
///   - 單寶貝：Name（`d41MUZ`）＋Sep「 · 」（`WmQcz`）＋Age（`zk1yE`）三段——姓名 600 主墨，
///     「 · 年齡」regular 次墨。
///   - 多寶貝：Multi Caption（`x7k2o6`）單一字串「小安 · 2 歲 3 個⁠月、小明 · 8 個⁠月」——
///     整串 600 主墨，AX3 也同一字串（`HLXo3` 板 `kmbyt`，靠自然折行，不改一行一人）。
///
/// 字串一律取 `AlbumSignatureFormatter`（LS-201／LS-365「·」領銜規則的單一來源：姓名＋U+0020＋
/// 「·」＋U+00A0＋年齡，年齡內部 U+00A0、「個⁠月」「月⁠大」U+2060）——稿面三處單人片段同一字串
/// （LS-119 Notes `ca7bA`「全稿一義」），不在這裡另寫一份。
///
/// 年齡計算基準是**這則內容發生的當下**（`asOf`，日記 `entryDate`），不是今天。
///
/// 字級：稿面三個節點皆 `$fs-note`（17／AX3 40）＝ SwiftUI `.body`（17pt，AX3 40pt）；用語意
/// 字級而非絕對 pt，本身隨 Dynamic Type 縮放（這裡是純函式，拿不到 `@ScaledMetric` 環境）。
///
/// 顏色（LS-446 起依底色傳入，`Ink`）：稿面 `$print-ink`／`$print-ink-secondary` 只適用紙面
/// （`$print-paper`，深色仍是淺紙）。`DiaryCardView` 自 LS-446 起整張是紙面 → 傳 `.print`；
/// `DiaryDetailView` header 畫在 `lsBackground`（頁面底、無紙）上，深色會變暗——沿 LS-142
/// `motifs.md`「沒有紙的地方用 `$text-primary`／`$text-secondary`、不能沿用 print-ink」判準傳
/// `.text`（淺色 hex 與 print-ink 系完全相同，深色才反轉成可讀色）。
enum MultiChildCaptionFormatter {
    /// 署名所在的底色，決定主墨／次墨用哪一組 token（見型別文件「顏色」）。刻意沒有預設值——
    /// 每個呼叫端都要自己說明畫在紙上還是頁面底上。
    enum Ink {
        /// 頁面底（無紙）：`text-primary`／`text-secondary`，深色反轉。
        case text
        /// `print-paper` 紙面：`print-ink`／`print-ink-secondary`，不隨深色反轉。
        case print

        var primary: Color { self == .print ? .lsPrintInk : .lsTextPrimary }
        var secondary: Color { self == .print ? .lsPrintInkSecondary : .lsTextSecondary }
    }

    static func attributed(
        children: [Child], asOf date: Date, ink: Ink, timeZone: TimeZone = .current
    ) -> AttributedString {
        guard children.count == 1, let child = children.first else {
            var multi = AttributedString(
                AlbumSignatureFormatter.signatureText(
                    children: children, asOf: date, isOneLinePerPerson: false, timeZone: timeZone
                )
            )
            multi.font = .body.weight(.semibold)
            multi.foregroundColor = ink.primary
            return multi
        }
        let segment = AlbumSignatureFormatter.segment(for: child, asOf: date, timeZone: timeZone)
        var nameRun = AttributedString(child.name)
        nameRun.font = .body.weight(.semibold)
        nameRun.foregroundColor = ink.primary
        // 「 ·⎵年齡」＝ segment 扣掉開頭姓名——分隔字元與 NBSP 規則只在 `AlbumSignatureFormatter` 定義。
        var ageRun = AttributedString(String(segment.dropFirst(child.name.count)))
        ageRun.font = .body
        ageRun.foregroundColor = ink.secondary
        return nameRun + ageRun
    }

    /// AX 字級多寶貝署名每人固定兩行（LS-447，LS-442 C4a，稿 `YXnTc` 第四欄／`gHl8E`）：第一行名字、
    /// 第二行「· 年齡」。兩行是兩個 `Text`、不靠 `\n`——折行點由版面決定，字串內的 U+00A0／U+2060 照舊。
    /// 字串取 `AlbumSignatureFormatter.segment(for:)`（單一來源）：名字之後的 U+0020 是「可斷」空白，
    /// 兩行拆開後會變成名字行的尾隨空白，所以在這裡丟掉，第二行以「·」領銜。
    static func twoLines(
        for child: Child, asOf date: Date, timeZone: TimeZone = .current
    ) -> (name: String, age: String) {
        let segment = AlbumSignatureFormatter.segment(for: child, asOf: date, timeZone: timeZone)
        let rest = segment.dropFirst(child.name.count).drop { $0 == " " }
        return (child.name, String(rest))
    }
}
