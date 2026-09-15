import SwiftUI
@testable import LittleSprout
import XCTest

/// LS-273：頭像圓圈的 `AsyncImage` 必須**無條件**掛在 overlay 上（`url` 參數本身可為 nil），
/// 不能包在「有沒有簽名 URL」的 `if let avatarURL` 分支裡。
///
/// 本機重現（證據 `.claude/evidence/LS-273/qa-e2e/browse-20260914-213840/`）：在寶貝編輯頁
/// 第一次幫一個**本來沒有頭像**的寶貝選照片存檔，回到列表後那一列連續 30 秒仍是姓名縮寫圓，
/// 期間 Storage log **完全沒有任何 GET**（`storage.log`：簽名 POST 之後 33 秒才出現第一個
/// GET，而那個 GET 是因為測試又點進編輯頁、由另一個 view 實例發出的）。app log 顯示 store
/// 這一層全對：`update_child` 回來 → `listChildren` 帶回新路徑 → 簽名回來 →
/// 世代守門 `gen=5 latest=5` 相等、`avatarSignedURLs` 與 `avatarCacheBust` 都寫入了。
/// 也就是說 `avatarURL(for:)` 當下就回傳了正確的 URL，卡住的是 view 這一層。
///
/// 機制：`avatarURL` 從 nil 變成非 nil 時，`if let` 會讓 SwiftUI **新建**一個 `AsyncImage`，
/// 而這次新建恰好落在「儲存成功 → `dismiss()` → 導覽 pop 動畫」的同一瞬間；新建的
/// `AsyncImage` 內部下載 task 在真的送出 GET 之前就被 transition 的重建取消，而 `AsyncImage`
/// **不會自己重試**（URL 沒變＝它認為沒事可做），於是那一列就停在 `.empty`（＝畫縮寫）。
/// 同一段流程裡「換掉既有頭像」不會壞，正是因為那時 `AsyncImage` 已經存在、只是 `url` 參數
/// 換了值——實測 GET 在 20 毫秒內就送出、列表 0.1 秒內換圖。把 `AsyncImage` 提到條件式外面
/// 之後，「第一次設定頭像」與「換照片」走的是同一條路徑（同一個實例換 `url`），三輪實跑
/// 皆 0.1 秒刷新（`.claude/evidence/LS-273/qa-e2e/browse-20260914-214742/`）。
///
/// 為什麼測「型別字串」而不是測行為：這個缺陷只在導覽 pop 的重建時序下才發作，
/// `UIHostingController` 裡單獨渲染一個 `ChildAvatarView` 重現不出來（修法前後都會發請求），
/// 所以行為測試守不住它。真正要釘住的不變量是**結構**——`AsyncImage` 不可以位於條件分支內，
/// 而 `body` 的靜態型別剛好就是這件事的機械判準：包在 `if let` 裡時型別是
/// `…_OverlayModifier<_ConditionalContent<AsyncImage<…>, …>>`，提到外面之後
/// `AsyncImage` 之前不再有 `_ConditionalContent`。`AsyncImage` 的 content closure 自己也有
/// 一個 `if case .success` 分支（型別在 `AsyncImage<…>` 的**內部**），所以判準不是「整串沒有
/// `_ConditionalContent`」。
///
/// LS-275（池 `f8c5941c` i2，merge-review LS-273 R1 `498c8e5a`）：判準原本是「`AsyncImage`
/// 之前沒有」，對無關的頂層條件式（例如 body 外層加 `if isDimmed { … } else { … }`）也會假
/// 紅——收窄成「`_OverlayModifier<` 之後到 `AsyncImage` 之間不得有 `_ConditionalContent`」，
/// 只釘住 overlay 段本身。
///
/// **未來任何想在這個元件加 `.id()`／強制身分重建的修法，都必須先讀
/// `ChildrenStoreAvatarListRefreshTests` 的檔頭**（LS-174 實測：`.id()` 會放大這個 race）。
final class ChildAvatarViewStructureTests: XCTestCase {
    @MainActor
    func test_body_asyncImageIsNotWrappedInConditionalBranch() {
        let typeName = String(describing: type(of: ChildAvatarView(name: "陳小安").body))

        guard let overlayStart = typeName.range(of: "_OverlayModifier<")?.upperBound else {
            return XCTFail("ChildAvatarView.body 的型別裡找不到 _OverlayModifier<：\(typeName)")
        }
        guard let asyncImageStart = typeName.range(
            of: "AsyncImage", range: overlayStart..<typeName.endIndex
        )?.lowerBound else {
            return XCTFail("ChildAvatarView.body 的型別裡（_OverlayModifier< 之後）找不到 AsyncImage：\(typeName)")
        }
        XCTAssertFalse(
            typeName[overlayStart..<asyncImageStart].contains("_ConditionalContent"),
            "AsyncImage 被包在條件分支裡（多半是 `if let avatarURL`）——avatarURL 由 nil 變成非 nil 時 "
                + "SwiftUI 會新建 AsyncImage，這次新建落在導覽 pop 動畫上就會讓下載 task 在送出 GET 之前"
                + "被取消且不重試（LS-273：第一次設定頭像後列表 30 秒不換圖、Storage 完全沒有 GET）。"
                + "型別字串：\(typeName)"
        )
    }

    /// LS-293：加上 `.failure` phase 重試（`.task(id: retryToken)`）＋`.id(retryToken)` 之後，
    /// 重跑一次同樣的判準——`AsyncImage` 仍必須直接掛在 overlay 段、不能因為重試機制的實作
    /// 方式（例如誤把 `AsyncImage` 包進 `if retryState... { } else { }`）重新落入
    /// `_ConditionalContent`。上面那條測試已經涵蓋這個不變量本身，這裡另立一條是專門釘住
    /// LS-293 這次改動沒有破壞它——之後改重試邏輯的人看測試名稱就知道要留意什麼。
    @MainActor
    func test_body_retryMechanismDoesNotReintroduceConditionalWrappingAroundAsyncImage() {
        let typeName = String(describing: type(of: ChildAvatarView(name: "陳小安").body))

        guard let overlayStart = typeName.range(of: "_OverlayModifier<")?.upperBound else {
            return XCTFail("ChildAvatarView.body 的型別裡找不到 _OverlayModifier<：\(typeName)")
        }
        guard let asyncImageStart = typeName.range(
            of: "AsyncImage", range: overlayStart..<typeName.endIndex
        )?.lowerBound else {
            return XCTFail("ChildAvatarView.body 的型別裡（_OverlayModifier< 之後）找不到 AsyncImage：\(typeName)")
        }
        XCTAssertFalse(
            typeName[overlayStart..<asyncImageStart].contains("_ConditionalContent"),
            "LS-293 加的重試機制（retryToken／.id()）把 AsyncImage 重新包進條件分支了：\(typeName)"
        )
    }
}
