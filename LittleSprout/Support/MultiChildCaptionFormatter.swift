import SwiftUI

/// 多寶貝 caption 格式（LS-126 票文 Scope 3）：
///   - 單寶貝：「姓名 · 年齡」
///   - 多寶貝：「姓名 年齡、姓名 年齡」（頓號分人，不用「·」）
///
/// 年齡段沿用既有 `BirthdayFormat.ageDescription`（票文 Scope 5：`ageDescription` 沿用
/// `BirthdayFormat`），計算基準是**這則內容發生的當下**（`asOf`，通常是日記 `entryDate`／
/// 時間軸項目 `occurredAt`），不是今天——「這則回憶被記錄下來的時候，孩子幾歲」。
///
/// 年齡段內的數字與單位一律用不斷行空格（`\u{00A0}`）取代一般空格，避免「2」與「歲」被自動
/// 斷行拆開、或「·」落單在行首（票文 Scope 3）。
enum MultiChildCaptionFormatter {
    /// 純資料版——不含樣式，供單元測試斷言字串內容與不斷行空格，不需要建立 View／
    /// AttributedString 就能驗證格式規則。
    struct Segment: Equatable {
        let name: String
        /// 已把一般空格換成 `\u{00A0}` 的年齡描述，例如「2\u{00A0}歲\u{00A0}3\u{00A0}個月」。
        let age: String
    }

    static func segments(children: [Child], asOf date: Date, calendar: Calendar = .current) -> [Segment] {
        children.map { child in
            let age = BirthdayFormat.ageDescription(birthday: child.birthday, now: date, calendar: calendar)
                .replacingOccurrences(of: " ", with: "\u{00A0}")
            return Segment(name: child.name, age: age)
        }
    }

    /// 年齡段降一階（MN-15）：姓名 `.body`／`.semibold`／`$text-primary`，年齡
    /// `.footnote`（對齊 `AppFontToken.meta` 的 `relativeStyle`，同一個 token 步階往下走
    /// 一階剛好落在這裡）／`$text-secondary`。用 SwiftUI 語意字級（`.body`／`.footnote`）
    /// 而不是絕對 pt 值，兩者本身就會隨 Dynamic Type 縮放，不需要另外套
    /// `@ScaledMetric`（那只能在 View body 內取得環境，這裡是純函式）。
    static func attributed(children: [Child], asOf date: Date, calendar: Calendar = .current) -> AttributedString {
        let segs = segments(children: children, asOf: date, calendar: calendar)
        var result = AttributedString()
        for (index, seg) in segs.enumerated() {
            if index > 0 {
                result += AttributedString("、")
            }
            var nameRun = AttributedString(seg.name)
            nameRun.font = .body.weight(.semibold)
            nameRun.foregroundColor = Color.lsTextPrimary
            result += nameRun

            result += AttributedString(segs.count == 1 ? " · " : " ")

            var ageRun = AttributedString(seg.age)
            ageRun.font = .footnote
            ageRun.foregroundColor = Color.lsTextSecondary
            result += ageRun
        }
        return result
    }
}
