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
    /// 「N 個月大」／「Y 歲 M 個月」兩種格式都有「個月」這個無空白的相鄰組合。
    ///
    /// LS-365（LS-367 Notes `L0xP2` ②）：「月」「大」之間也插 WORD JOINER——AX3 實測
    /// 「小饅頭 · 8 個月」／「大」孤字（LS-367 定案 1 `AGF13`）。
    static func hardenedAge(_ age: String) -> String {
        age
            .replacingOccurrences(of: "個月", with: "個\u{2060}月")
            .replacingOccurrences(of: "月大", with: "月\u{2060}大")
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// 單一寶貝的「暱稱 · 年齡」片段。
    ///
    /// LS-365（LS-367 Notes `L0xP2` ①）：「·」前維持一般可斷空白（U+0020）、「·」後改不斷行
    /// 空格（U+00A0）——單人一行放不下時只能在姓名後折行，「·」領銜下一行（「小安」／
    /// 「· 2 歲 3 個月」，LS-201 核可稿面）。原本「·」後也是 U+0020，AX3 會折成「小安 ·」／
    /// 「2 歲 3 個月」，與稿相反。「·」前不能也換 NBSP：會把姓名最後一字一併鎖進同一個不可斷
    /// 區塊，AX3 實測會產生單字孤兒（LS-142 Notes `epDnW`）。相簿卡署名列（`AlbumSummaryCardView`）
    /// 與時間軸照片卡（`PhotoCardView`）共用這支，兩邊折行一起變。
    ///
    /// LS-334：改吃 `timeZone: TimeZone`，不再吃 `calendar: Calendar`——同
    /// `BirthdayFormat.wireString`／`ageDescription` 原則，裝置曆法識別碼不會有機會流進
    /// `BirthdayFormat.ageDescription`。
    static func segment(for child: Child, asOf date: Date, timeZone: TimeZone = .current) -> String {
        let age = hardenedAge(BirthdayFormat.ageDescription(birthday: child.birthday, now: date, timeZone: timeZone))
        return "\(child.name) ·\u{00A0}\(age)"
    }

    /// 署名列文字——`isOneLinePerPerson` 為 true（AX3）時多寶貝改用 `\n` 分隔，否則用「、」。
    /// 零寶貝回傳單一半形空白（保留高度，見型別文件註解）。
    static func signatureText(
        children: [Child], asOf date: Date, isOneLinePerPerson: Bool, timeZone: TimeZone = .current
    ) -> String {
        guard !children.isEmpty else { return " " }
        let separator = isOneLinePerPerson ? "\n" : "、"
        return children.map { segment(for: $0, asOf: date, timeZone: timeZone) }.joined(separator: separator)
    }

    /// Caption 文字——相簿名＋張數，AX3 各自成行（`\n`），一般字級用「·」同列。
    static func captionText(title: String, photoCount: Int, isMultiline: Bool) -> String {
        let countText = "\(photoCount) 張相片"
        return isMultiline ? "\(title)\n\(countText)" : "\(title) · \(countText)"
    }
}
