import XCTest

/// LS-458（LS-413 池 P1 `f608d582`，另 `e0f65a8f` 的 `AlbumsViewIPadTests` 同型）：iPad `NavigationSplitView` 側欄開關。
///
/// 慢 runner 上「點側邊欄開關鈕」的 tap 可能沒生效——ci-ipad run 38008119531 的 log：`Tap "隱藏側邊欄" Button` 前的
/// `Find` 吃掉 10 秒、`Check for interrupting elements` 3 秒，事件送出後 7.5 秒內 `顯示側邊欄` 都沒出現，最後
/// 一份 accessibility 快照裡開關鈕仍是「隱藏側邊欄」、版面還在側欄展開才有的單欄推入（`BackButton`「寶貝」）。
/// 本機（快機）怎麼跑都綠，所以不能靠本機重現——改成**以狀態驅動**：開關鈕的 label 就是狀態（「隱藏側邊欄」＝
/// 展開中；「顯示側邊欄」＝已收起），tap 之後等 label 翻成「顯示側邊欄」（`UITestTimeouts.standard`），
/// 逾時**且 label 仍是展開態**才重點（最多 `attempts` 次）。重點之前一定先看過 label 沒變，不會把「只是變慢」的第一下
/// 再翻回去。
extension XCUIApplication {
    /// 收起側欄並等到「顯示側邊欄」鈕可點；回傳是否成功（呼叫端用自己的訊息斷言）。
    /// 開關鈕 label 措辭不綁死，用 CONTAINS「側邊欄」找（同 `TimelineViewIPadTests`）。
    func collapseSidebarUntilShowButtonHittable(
        timeout: TimeInterval = UITestTimeouts.standard, attempts: Int = 3
    ) -> Bool {
        let showButton = buttons["顯示側邊欄"]
        let toggle = buttons.matching(NSPredicate(format: "label CONTAINS %@", "側邊欄")).firstMatch
        for _ in 0..<attempts {
            guard toggle.waitForHittable(timeout: timeout) else { return false }
            if toggle.label == "顯示側邊欄" { return true }
            toggle.tap()
            if showButton.waitForHittable(timeout: timeout) { return true }
        }
        return false
    }
}
