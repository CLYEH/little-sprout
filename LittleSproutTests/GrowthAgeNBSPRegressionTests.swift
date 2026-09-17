@testable import LittleSprout
import XCTest

/// LS-312 R3（merge-review R2 m2，orchestrator 裁決 `8cf0114c`）：Identity Header 年齡字串
/// （`BirthdayFormat.ageDescription`）回傳一般空白（U+0020），稿面 `jp6ka`／`pjrd7` 對應節點
/// codepoint 是不斷行空白＋WORD JOINER（同 LS-309 `design_identity_header_check.py` 驗的形狀）
/// ——長字串（例如「11 歲 11 個月」）＋AX3＋iPhone 窄欄（Identity Header 右側還要留 44pt
/// 「編輯」熱區）時可能在空白處換行，斷成「…個」／「月」孤字。
///
/// 修法：套用既有 `AlbumSignatureFormatter.hardenedAge(_:)`（`個月` → `個\u{2060}月`、空白 →
/// `\u{00A0}`），不改 `BirthdayFormat` 本體（那支還餵著 `childRowContent` 的 `Pill` 等既有畫面）。
///
/// 沒有 ViewInspector 測不到 `Text` 實際渲染的字串內容（同 `GrowthDetailTitleRegressionTests`
/// 文件註解點名的既有理由），這裡用原始碼文字守衛：mutation 把 `hardenedAge(...)` 拿掉、直接
/// 傳 `BirthdayFormat.ageDescription(...)`，這支測試會抓到。
final class GrowthAgeNBSPRegressionTests: XCTestCase {
    private func sourceText(relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let worktreeRoot = testFileURL
            .deletingLastPathComponent() // LittleSproutTests/
            .deletingLastPathComponent() // worktree 根目錄
        let sourceURL = worktreeRoot.appendingPathComponent(relativePath)
        let fullText = try String(contentsOf: sourceURL, encoding: .utf8)
        return fullText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// mutation：把 `identityHeader()` 的年齡 `Text(...)` 改回
    /// `Text(BirthdayFormat.ageDescription(birthday: child.birthday))`（不套 `hardenedAge`），
    /// 這支測試轉紅——長字串＋AX3＋窄欄可能斷出孤字（稿面規則失守）。
    func test_identityHeaderAge_appliesHardenedAge_notRawAgeDescription() throws {
        let source = try sourceText(relativePath: "LittleSprout/Features/Growth/ChildGrowthDetailView.swift")

        XCTAssertTrue(
            source.contains(
                "Text(AlbumSignatureFormatter.hardenedAge(BirthdayFormat.ageDescription(birthday: child.birthday)))"
            ),
            "Identity Header 年齡字串應該套 AlbumSignatureFormatter.hardenedAge(_:)（NBSP／WORD"
                + " JOINER），不能直接吃 BirthdayFormat.ageDescription 的原始空白——長字串＋AX3"
                + "＋窄欄會斷出孤字"
        )
    }

    /// `hardenedAge(_:)` 本身的轉換規則（不是 View 接線）已有 `AlbumSignatureFormatterTests`
    /// 覆蓋——這裡只再核一次「個月」＋一般空白都被接住，避免這支測試只驗字面呼叫但轉換規則
    /// 本身悄悄壞掉時反而測不出來。
    func test_hardenedAge_convertsSpacesAndWordJoinsGeYue() {
        let hardened = AlbumSignatureFormatter.hardenedAge("1 歲 4 個月")

        XCTAssertEqual(hardened, "1\u{00A0}歲\u{00A0}4\u{00A0}個\u{2060}月")
    }
}
