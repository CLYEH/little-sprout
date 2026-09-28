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
/// 顏色：稿面 `$print-ink`／`$print-ink-secondary` 只適用紙面（`$print-paper`，深色仍是淺紙）；
/// 本元件實際畫在 `lsSurface`（`DiaryCardView`）／`lsBackground`（`DiaryDetailView`）上，深色
/// 會變暗——沿 LS-142 `motifs.md`「沒有紙的地方用 `$text-primary`／`$text-secondary`、不能沿用
/// print-ink」判準取同角色的 text token（淺色 hex 與 print-ink 系完全相同，深色才反轉成可讀色）。
enum MultiChildCaptionFormatter {
    static func attributed(children: [Child], asOf date: Date, timeZone: TimeZone = .current) -> AttributedString {
        guard children.count == 1, let child = children.first else {
            var multi = AttributedString(
                AlbumSignatureFormatter.signatureText(
                    children: children, asOf: date, isOneLinePerPerson: false, timeZone: timeZone
                )
            )
            multi.font = .body.weight(.semibold)
            multi.foregroundColor = Color.lsTextPrimary
            return multi
        }
        let segment = AlbumSignatureFormatter.segment(for: child, asOf: date, timeZone: timeZone)
        var nameRun = AttributedString(child.name)
        nameRun.font = .body.weight(.semibold)
        nameRun.foregroundColor = Color.lsTextPrimary
        // 「 ·⎵年齡」＝ segment 扣掉開頭姓名——分隔字元與 NBSP 規則只在 `AlbumSignatureFormatter` 定義。
        var ageRun = AttributedString(String(segment.dropFirst(child.name.count)))
        ageRun.font = .body
        ageRun.foregroundColor = Color.lsTextSecondary
        return nameRun + ageRun
    }
}
