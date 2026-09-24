import Foundation
@testable import LittleSprout
import XCTest

/// `AlbumSignatureFormatter`（LS-165 票文驗收：「署名規則單元測試」；LS-142 Handoff Notes
/// `epDnW`／R4 `KBNSX`／R5 `IaOHK`）：單寶貝／多寶貝／零寶貝三態、NBSP／WORD JOINER 硬化、
/// AX3 一行一人。
final class AlbumSignatureFormatterTests: XCTestCase {
    /// 固定「現在」為某個已知日期，讓 `ageDescription` 算出來的年齡是決定性的，不隨測試執行
    /// 當下的真實日期漂移。
    private let now = ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z")!

    private func makeChild(name: String, yearsAgo: Int = 0, monthsAgo: Int = 0) -> Child {
        var components = DateComponents()
        components.year = -yearsAgo
        components.month = -monthsAgo
        let birthday = Calendar(identifier: .gregorian).date(byAdding: components, to: now)!
        return Child(id: UUID(), name: name, birthday: birthday, avatarURL: nil, deletedAt: nil, createdAt: now)
    }

    // MARK: - hardenedAge

    func test_hardenedAge_replacesSpacesWithNBSP() {
        let hardened = AlbumSignatureFormatter.hardenedAge("2 歲 3 個月")
        XCTAssertFalse(hardened.contains(" "), "一般空格應該全部被取代")
        XCTAssertTrue(hardened.contains("\u{00A0}"), "應該含有不斷行空格")
    }

    func test_hardenedAge_insertsWordJoinerBetween個月() {
        let hardened = AlbumSignatureFormatter.hardenedAge("6 個月大")
        XCTAssertTrue(hardened.contains("個\u{2060}月"), "「個」「月」之間應插入 WORD JOINER 防止拆字")
    }

    func test_hardenedAge_yearsOnly_hasNoWordJoiner() {
        // 「N 歲」沒有「個月」這個相鄰組合，不該被誤插 WORD JOINER。
        let hardened = AlbumSignatureFormatter.hardenedAge("2 歲")
        XCTAssertFalse(hardened.contains("\u{2060}"))
    }

    // MARK: - segment

    func test_segment_breakableSpaceBeforeDot_nbspAfterDot() {
        let child = makeChild(name: "小安", yearsAgo: 2, monthsAgo: 3)
        let segment = AlbumSignatureFormatter.segment(for: child, asOf: now)
        // LS-365（LS-367 Notes `L0xP2` ①）：「·」前 U+0020（可斷，姓名後折行）、「·」後 U+00A0
        // （不可斷，「·」領銜下一行）——改回 U+0020 會讓 AX3 折成「小安 ·」／「2 歲 3 個月」。
        XCTAssertTrue(segment.hasPrefix("小安 ·\u{00A0}"), "應為「姓名 ·(NBSP)年齡」格式，實際：\(segment)")
        XCTAssertFalse(segment.hasPrefix("小安\u{00A0}"), "「·」前必須是可斷空白，不能把姓名鎖進不可斷區塊")
        XCTAssertTrue(segment.contains("2\u{00A0}歲\u{00A0}3\u{00A0}個\u{2060}月"))
    }

    func test_hardenedAge_insertsWordJoinerBetween月大() {
        // LS-365（LS-367 Notes `L0xP2` ②）：AX3 實測「小饅頭 · 8 個月」／「大」孤字。
        XCTAssertEqual(AlbumSignatureFormatter.hardenedAge("8 個月大"), "8\u{00A0}個\u{2060}月\u{2060}大")
    }

    // MARK: - signatureText

    func test_signatureText_zeroChildren_returnsSingleSpace_notEmptyString() {
        // 零寶貝卡署名列保留高度：回傳單一半形空白，不是空字串（LS-142 brand 十條 #10）。
        let text = AlbumSignatureFormatter.signatureText(children: [], asOf: now, isOneLinePerPerson: false)
        XCTAssertEqual(text, " ")
    }

    func test_signatureText_singleChild_isNameDotAge() {
        let child = makeChild(name: "小安", yearsAgo: 2, monthsAgo: 3)
        let text = AlbumSignatureFormatter.signatureText(children: [child], asOf: now, isOneLinePerPerson: false)
        XCTAssertTrue(text.hasPrefix("小安 ·\u{00A0}"), "實際：\(text)")
    }

    // MARK: - LS-365 三態逐字（照片卡署名，LS-367 Notes `L0xP2`；年齡以 ageDescription 實際輸出為準）

    /// 逐字比對用 UTC 固定時區——`makeChild` 用裝置時區算生日，跨時區跑年齡可能差一個月；
    /// 這組測試要釘住的是「逐字元」，不能讓時區漂移混進來。
    private let utc = TimeZone(identifier: "UTC")!

    private func makeUTCChild(name: String, birthday: String) -> Child {
        let date = ISO8601DateFormatter().date(from: "\(birthday)T00:00:00Z")!
        return Child(id: UUID(), name: name, birthday: date, avatarURL: nil, deletedAt: nil, createdAt: now)
    }

    func test_signatureText_exact_singleChild_yearsAndMonths() {
        let child = makeUTCChild(name: "小安", birthday: "2024-06-05")
        let text = AlbumSignatureFormatter.signatureText(
            children: [child], asOf: now, isOneLinePerPerson: false, timeZone: utc
        )
        XCTAssertEqual(text, "小安 ·\u{00A0}2\u{00A0}歲\u{00A0}3\u{00A0}個\u{2060}月")
    }

    func test_signatureText_exact_threeChildren_allThreeAgeShapes_joinedByDunHao() {
        // ageDescription 三種輸出形狀各一：整歲「N 歲」／「Y 歲 M 個月」／未滿一歲「N 個月大」。
        let children = [
            makeUTCChild(name: "陳彥廷", birthday: "2023-09-05"),
            makeUTCChild(name: "小饅頭", birthday: "2025-01-05"),
            makeUTCChild(name: "Emma Chen", birthday: "2026-01-05")
        ]
        let text = AlbumSignatureFormatter.signatureText(
            children: children, asOf: now, isOneLinePerPerson: false, timeZone: utc
        )
        XCTAssertEqual(
            text,
            "陳彥廷 ·\u{00A0}3\u{00A0}歲"
                + "、小饅頭 ·\u{00A0}1\u{00A0}歲\u{00A0}8\u{00A0}個\u{2060}月"
                + "、Emma Chen ·\u{00A0}8\u{00A0}個\u{2060}月\u{2060}大"
        )
    }

    func test_segment_exact_eachPerson_matchesSignatureParts() {
        // 照片卡「一行一人」候選每人一個 Text（`PhotoCardSignature`），直接用 `segment`——
        // 要跟串接版的每一段逐字相同，兩個候選才不會對同一個人印出不同字串。
        let child = makeUTCChild(name: "Emma Chen", birthday: "2026-01-05")
        XCTAssertEqual(
            AlbumSignatureFormatter.segment(for: child, asOf: now, timeZone: utc),
            "Emma Chen ·\u{00A0}8\u{00A0}個\u{2060}月\u{2060}大"
        )
    }

    func test_signatureText_exact_zeroChildren_isSingleHalfWidthSpace() {
        let text = AlbumSignatureFormatter.signatureText(
            children: [], asOf: now, isOneLinePerPerson: false, timeZone: utc
        )
        XCTAssertEqual(text.unicodeScalars.map(\.value), [0x20], "未標記＝單一半形空白（U+0020），卡高不變")
    }

    func test_signatureText_multipleChildren_regularSize_joinedByDunHao() {
        let anAn = makeChild(name: "小安", yearsAgo: 2, monthsAgo: 3)
        let xiaoMing = makeChild(name: "小明", monthsAgo: 8)
        let text = AlbumSignatureFormatter.signatureText(
            children: [anAn, xiaoMing], asOf: now, isOneLinePerPerson: false
        )
        XCTAssertTrue(text.contains("、"), "一般字級多寶貝應用「、」串接，實際：\(text)")
        XCTAssertFalse(text.contains("\n"), "一般字級不應含換行")
    }

    func test_signatureText_multipleChildren_ax3_oneLinePerPerson_usesNewlineNotDunHao() {
        let anAn = makeChild(name: "小安", yearsAgo: 2, monthsAgo: 3)
        let xiaoMing = makeChild(name: "小明", monthsAgo: 8)
        let text = AlbumSignatureFormatter.signatureText(
            children: [anAn, xiaoMing], asOf: now, isOneLinePerPerson: true
        )
        // R4 KBNSX／R5 IaOHK：AX3 一行一人，用顯式換行取代「、」，不依賴字元種類斷行。
        XCTAssertTrue(text.contains("\n"), "AX3 應該用顯式換行分隔每個人，實際：\(text)")
        XCTAssertFalse(text.contains("、"), "AX3 不應再用「、」分隔，實際：\(text)")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "兩個寶貝應該各自一行")
    }

    // MARK: - captionText

    func test_captionText_regular_joinsWithMiddleDotOnOneLine() {
        let text = AlbumSignatureFormatter.captionText(title: "上禮拜的動物園一日遊", photoCount: 12, isMultiline: false)
        XCTAssertEqual(text, "上禮拜的動物園一日遊 · 12 張相片")
    }

    func test_captionText_ax3_splitsTitleAndCountOntoSeparateLines() {
        let text = AlbumSignatureFormatter.captionText(title: "上禮拜的動物園一日遊", photoCount: 12, isMultiline: true)
        XCTAssertEqual(text, "上禮拜的動物園一日遊\n12 張相片")
    }

    func test_captionText_zeroPhotos_stillReadsZeroSheets() {
        // MN-3 用詞規則：計數名詞用「相片」，這裡順帶釘住 0 張的措辭不會變成奇怪的複數/單數問題
        // （中文沒有複數變化，純粹確認數字 0 能正常組字串）。
        let text = AlbumSignatureFormatter.captionText(title: "新相簿", photoCount: 0, isMultiline: false)
        XCTAssertEqual(text, "新相簿 · 0 張相片")
    }
}
