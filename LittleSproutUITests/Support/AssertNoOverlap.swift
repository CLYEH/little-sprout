import XCTest

/// LS-268（池 `f07c26d1`，`uitest-dup-helper-check.sh` 真陽性）：`assertNoOverlap` 原本在
/// `ContentActionsAX3UITests.swift:116` 與 `InteractionRowUITests.swift:231` 各自持有一份
/// byte-identical 複本，抽成單一共用函式（同 `XCUIElement+Waits.swift` 既有的 LS-263 抽檔
/// 模式），兩檔呼叫點改成呼叫這支共用函式，語法不變。
///
/// 寫成全域函式而非 `extension XCTestCase`：`XCTAssertFalse` 本身是全域函式，不需要
/// `XCTestCase` 的 instance context 才能回報失敗（`file`／`line` 已經帶著呼叫端位置）；用
/// extension 會讓這個方法名對所有 `XCTestCase` 子類別可見，跟 `AlbumDetailAX3UITests.swift`
/// 本體不同的同名 `private func assertNoOverlap` 撞名時，Swift 會把它當成「覆寫」要求存取層級
/// 至少跟 extension 一樣（編譯錯誤：`Overriding instance method must be as accessible as
/// the declaration it overrides`）。全域函式沒有這個問題——`AlbumDetailAX3UITests` 那支
/// `private func` 在自己檔案內的呼叫點單純覆蓋（shadow）掉同名全域函式，兩者互不相干。
///
/// `AlbumDetailAX3UITests.swift` 的同名 `assertNoOverlap` 本體不同（不篩 `isHittable`）——
/// `uitest-dup-helper-check.sh` 正確地沒把它算進重複，這裡也不動它。
///
/// 用 frame 交集判斷任兩個元素是否重疊——同 `DeleteConfirmationAX3UITests
/// .assertButtonsReachableAndDoNotOverlap` 的既有手法，比單純比較 y 座標更不受版面假設影響。
/// 只比對真的 hittable（在畫面上）的元素，捲動裁掉、不在畫面上的元素本來就不該納入重疊判斷。
@MainActor
func assertNoOverlap(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
    let visible = elements.filter(\.isHittable)
    for firstIndex in 0..<visible.count {
        for secondIndex in (firstIndex + 1)..<visible.count {
            let first = visible[firstIndex]
            let second = visible[secondIndex]
            XCTAssertFalse(
                first.frame.intersects(second.frame),
                "AX3 下「\(first.label)」與「\(second.label)」不應該重疊：\(first.frame) vs \(second.frame)",
                file: file, line: line
            )
        }
    }
}
