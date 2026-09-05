import Foundation

/// 相簿列表卡片（`cmp/Card Album`，LS-142 Handoff Notes `epDnW`／`R4 KBNSX`／`R5 IaOHK`）
/// 的 Caption（相簿名＋張數）與 Signature Line（署名列）格式——刻意跟 `MultiChildCaptionFormatter`
/// （時間軸日記卡用）分開一個型別：兩者服務不同元件，姓名/年齡的連接規則不同（這裡姓名與
/// 年齡之間一律用「·」，不論單寶貝或多寶貝；`MultiChildCaptionFormatter` 多寶貝時姓名/年齡
/// 之間改用純空白，見該檔文件註解），硬套同一個 formatter 會把兩邊的差異寫成一堆 if-else
/// 分支，不如各自獨立清楚。
///
/// 三條規則（皆已用 LS-142 核可頁取證截圖 `puHZ5.png`／`IjWOp.png` 交叉核對）：
///   - 單寶貝：`"{暱稱} · {年齡}"`。
///   - 多寶貝（≥2）：一般字級用「、」串接多組「暱稱 · 年齡」；AX3（`.accessibility3` 起，
///     同 `SectionTabBar.isAX3` 既有斷點慣例）改一行一人，用顯式換行 `\n` 取代「、」——
///     R4 KBNSX／R5 IaOHK：AX3 下不依賴字元種類斷行，唯一穩妥的是用 `\n` 直接指定斷點。
///   - 零寶貝：回傳單一半形空白 `" "`——署名列保留高度、讀者靠「這行是空白」本身辨識零寶貝卡，
///     不靠卡片整體變矮辨識（brand 十條 #10「空欄位卡不塌縮」）。
///
/// Caption（相簿名＋張數）同理：一般字級 `"{title} · {count} 張相片"`；AX3 改 `"{title}\n{count} 張相片"`
/// （`IjWOp.png` 核可頁截圖：AX3 下相簿名與張數各自成行）。
enum AlbumSignatureFormatter {
    /// 年齡片語內部空白換成不斷行空格（`\u{00A0}`），「個」「月」之間插入 WORD JOINER
    /// （`\u{2060}`）防止拆成孤字——同 `MultiChildCaptionFormatter.segments` 的既有理由，
    /// 這裡額外處理「個月」相鄰（無空白）也要接住，因為 `BirthdayFormat.ageDescription` 的
    /// 「N 個月大」／「Y 歲 M 個月」兩種格式都有「個月」這個無空白的相鄰組合。姓名與年齡之間
    /// 的「 · 」刻意維持一般可斷空白（U+0020）——若也用 NBSP 包住會把姓名最後一字一併鎖進
    /// 同一個不可斷區塊，AX3 實測會產生單字孤兒（LS-142 Notes `epDnW`）。
    static func hardenedAge(_ age: String) -> String {
        age
            .replacingOccurrences(of: "個月", with: "個\u{2060}月")
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// 單一寶貝的「暱稱 · 年齡」片段。
    static func segment(for child: Child, asOf date: Date, calendar: Calendar = .current) -> String {
        let age = hardenedAge(BirthdayFormat.ageDescription(birthday: child.birthday, now: date, calendar: calendar))
        return "\(child.name) · \(age)"
    }

    /// 署名列文字——`isOneLinePerPerson` 為 true（AX3）時多寶貝改用 `\n` 分隔，否則用「、」。
    /// 零寶貝回傳單一半形空白（保留高度，見型別文件註解）。
    static func signatureText(
        children: [Child], asOf date: Date, isOneLinePerPerson: Bool, calendar: Calendar = .current
    ) -> String {
        guard !children.isEmpty else { return " " }
        let separator = isOneLinePerPerson ? "\n" : "、"
        return children.map { segment(for: $0, asOf: date, calendar: calendar) }.joined(separator: separator)
    }

    /// Caption 文字——相簿名＋張數，AX3 各自成行（`\n`），一般字級用「·」同列。
    static func captionText(title: String, photoCount: Int, isMultiline: Bool) -> String {
        let countText = "\(photoCount) 張相片"
        return isMultiline ? "\(title)\n\(countText)" : "\(title) · \(countText)"
    }
}
