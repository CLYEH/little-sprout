@testable import LittleSprout
import XCTest

/// LS-245（池 `7f77856c`，LS-241 R1 merge-review m1）：`DiaryDetailView` 留言 sheet／「⋯」
/// 內容操作表原本各自用獨立的 `@State`（`showsCommentsSheet`／`contentActionsContext`）——
/// 兩者非同步窗口重疊時第二個呈現被系統丟棄，且 `contentActionsContext.id` 恆為
/// `target.id`（＝diaryID），卡在非 nil 之後再次觸發（同一個 id）不會被 `.sheet(item:)` 視為
/// 新的呈現而重新彈出。收斂成單一 `activeSheet: DiaryDetailSheet?` 後，任何時刻只有一個 case
/// 是「目前要呈現的」——這是型別層級的結構保證（單一 `Optional` 不可能同時持有兩個值），不是
/// 靠執行期巧合。
///
/// **這裡沒有直接對 `DiaryDetailView` 實例讀寫 `activeSheet`**：實測過（見 PR 說明）——
/// `@State` 包裝的屬性在 View 尚未被 SwiftUI 安裝進畫面階層（沒有 `_location`）之前，
/// `wrappedValue` 的 `nonmutating set` 對值型別（例如這裡的 `DiaryDetailSheet?`）是無效的
/// no-op（讀回永遠是初始值），跟 `CommentsSheetViewTests.test_syncCommentCountIfKnown_...`
/// 能成功的原因不同——那支測試呼叫的 `view.store` 是參考型別（class），拿到的是同一個物件
/// 參照，`seedForPreview` 改的是物件「裡面」的狀態，不是重新指派 `@State` 本身。value 型別的
/// `@State` 若要驗證「觸發後真的呈現正確內容」需要真正安裝到畫面階層（UITest／
/// `ViewInspector`，本專案未導入後者）——這條路徑的「連續觸發兩來源仍能各自呈現」改由
/// `LittleSproutUITests/DiaryDetailCommentsUITests.swift`／`ContentActionsUITests.swift`
/// 既有的兩支測試各自覆蓋兩個來源仍可正確呈現（各自獨立驗證，PR body 說明為何沒有再疊一支
/// 「同一個 session 內連續觸發兩者」的 UITest：需要注入延遲才能穩定重現非同步窗口重疊，
/// LS-241 reviewer 本人也是 PLAUSIBLE、未實跑）。
///
/// 這裡能真正做到、且對回歸有意義的單元測試，是鎖住修好第二個根因（id 恆定）的不變量：
/// `DiaryDetailSheet` 兩個 case 的 `id` 命名空間不會相撞，即使底層的 `context.id` 剛好等於
/// `diaryID`——舊版的 bug 之所以「卡住不再重新呈現」，一部分原因正是 `contentActionsContext`
/// 重複觸發時 `id` 恆定（＝target.id＝diaryID）。
final class DiaryDetailSheetIDTests: XCTestCase {
    func test_commentsCase_and_contentActionsCase_neverCollideEvenWithSameUnderlyingID() {
        let diaryID = UUID()
        let context = DiaryContentActionsContext(
            target: ContentActionTarget(type: .diary, id: diaryID, familyID: UUID(), headline: "測試日記內容"),
            actions: [.report]
        )

        XCTAssertNotEqual(DiaryDetailSheet.comments.id, DiaryDetailSheet.contentActions(context).id)
    }

    /// mutation 對照：若 `.contentActions` 的 `id` 改回直接用 `context.id`（不加命名空間前綴），
    /// 且剛好同一顆 `DiaryDetailView` 的 diaryID 被拿來組出一個 `.comments` 用的假想 id
    /// （這裡直接構造 `DiaryDetailSheet.contentActions` 用同一個 `diaryID` 當 `target.id`，
    /// 驗證即使兩個來源共享同一份底層 UUID，命名空間前綴仍然讓兩者的 `id` 不同）——這支測試
    /// 直接鎖住 `contentActions-` 前綴這行程式碼，拿掉前綴（改成 `context.id.uuidString`）
    /// 且 `.comments` 剛好回同一個 UUID 字串時才會轉紅（目前 `.comments` 回固定字面
    /// `"comments"`，不會跟任何 UUID 字串相等，所以這支測試的鑑別力來自於「即使某天有人讓
    /// `.comments` 的 id 也帶 UUID，只要遺漏命名空間前綴就會撞」的防呆）。
    func test_diaryDetailSheetID_idsAreStableAndDistinctAcrossRepeatedConstruction() {
        let diaryID = UUID()
        let context = DiaryContentActionsContext(
            target: ContentActionTarget(type: .diary, id: diaryID, familyID: UUID(), headline: "測試日記內容"),
            actions: []
        )

        let firstID = DiaryDetailSheet.contentActions(context).id
        let secondID = DiaryDetailSheet.contentActions(context).id

        XCTAssertEqual(firstID, secondID, "同一個 context 重複取 id 應該得到相同結果（純函式，無隨機成分）")
        XCTAssertTrue(firstID.hasPrefix("contentActions-"), "應該帶命名空間前綴，不能只是裸的 UUID 字串")
    }
}
