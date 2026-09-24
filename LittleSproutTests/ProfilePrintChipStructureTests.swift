import SwiftUI
@testable import LittleSprout
import XCTest

/// LS-345：`ProfilePrintChip`（`SettingsView+Profile.swift`）的 `AsyncImage` 必須無條件掛在
/// `ZStack` 裡（`url` 參數本身可為 nil），不能包在 `if let avatarURL` 條件分支裡——同
/// `ChildAvatarViewStructureTests` 文件註解點名的 LS-273 教訓：`avatarURL` 由 nil 變成非 nil
/// 時，`if let` 會讓 SwiftUI 新建一個 `AsyncImage`，若這次新建剛好落在導覽 transition
/// （例如 `ProfileEditView` 存檔成功 `dismiss()` 回設定頁）上，新建的下載 task 可能在送出 GET
/// 之前就被取消、且 `AsyncImage` 不會自己重試。
final class ProfilePrintChipStructureTests: XCTestCase {
    /// mutation：把 `ProfilePrintChip.body` 的 `AsyncImage` 改包進 `if let avatarURL { ... }
    /// else { ... }`，這支測試會抓到——型別字串裡 `AsyncImage` 之前不該出現 `_ConditionalContent`。
    @MainActor
    func test_body_asyncImageIsNotWrappedInConditionalBranch() {
        let typeName = String(describing: type(of: ProfilePrintChip().body))

        guard let asyncImageRange = typeName.range(of: "AsyncImage") else {
            return XCTFail("ProfilePrintChip.body 的型別裡找不到 AsyncImage：\(typeName)")
        }
        let beforeAsyncImage = typeName[typeName.startIndex..<asyncImageRange.lowerBound]
        XCTAssertFalse(
            beforeAsyncImage.contains("_ConditionalContent"),
            "AsyncImage 被包在條件分支裡（多半是 `if let avatarURL`）——avatarURL 由 nil 變成非 nil 時 " +
                "SwiftUI 會新建 AsyncImage，這次新建若落在導覽 transition 上會讓下載 task 在送出 GET 之前 " +
                "被取消且不重試（同 LS-273 教訓）。型別字串：\(typeName)"
        )
    }
}
