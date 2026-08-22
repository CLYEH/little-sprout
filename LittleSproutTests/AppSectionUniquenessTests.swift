import XCTest
@testable import LittleSprout

/// `AppSection` 的 `title` 與 `systemImage` 各自必須無重複；一旦重複，TabView 分頁
/// 或 sidebar 就會出現兩個看起來一樣的項目，使用者無法分辨要點哪一個。
/// `AppSectionTests` 已經鎖住「非空」與「SF Symbol 存在」，但沒鎖住「彼此不重複」，
/// 這條測試補上這個洞：未來有人新增/複製 case 時忘了改標題或圖示會在這裡被擋下。
final class AppSectionUniquenessTests: XCTestCase {
    func testAllTitlesAreUnique() {
        let titles = AppSection.allCases.map(\.title)
        XCTAssertEqual(
            titles.count,
            Set(titles).count,
            "存在重複的標題：\(titles)；使用者會在分頁或 sidebar 看到兩個文字相同的項目"
        )
    }

    func testAllSystemImagesAreUnique() {
        let symbols = AppSection.allCases.map(\.systemImage)
        XCTAssertEqual(
            symbols.count,
            Set(symbols).count,
            "存在重複的 SF Symbol：\(symbols)；使用者會在分頁或 sidebar 看到兩個圖示相同的項目"
        )
    }
}
