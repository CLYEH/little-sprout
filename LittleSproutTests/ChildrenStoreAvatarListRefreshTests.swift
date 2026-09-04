import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-174：儲存寶貝頭像後回到寶貝管理列表不即時刷新——找根因排查釘住的情境。從
/// `ChildrenStoreAvatarTests` 拆出獨立檔案——加完這條測試後那支檔案超過 SwiftLint
/// `type_body_length` 上限，理由同該檔文件註解「從 `ChildrenStoreTests` 拆出」的先例。
///
/// 找根因結論（詳見 PR body／handoff／`ChildrenStore.refreshAvatarSignedURLs` 文件註解）：
/// **store 這一層確實有缺陷**——`avatarCacheBust[path]` 原本在上傳成功「當下」就寫入，
/// `avatarSignedURLs` 要等 `reloadChildrenList` 內的簽名 RPC 回來才寫，中間隔著
/// `apiClient.updateChild` RPC 與簽名 RPC 兩個 `await`，`avatarURL(for:)` 因此在一次成功
/// 換頭像裡連續變了兩次（先是「新 cache-bust／舊簽名 URL」的過渡態，再變成最終值）。實機
/// 重現：連續換照片幾次後，這個過渡態會讓 `AsyncImage` 的下載 task 在真正發出 GET 之前被
/// 自己的下一次重繪取消，卡在縮寫、要切一次分頁才顯示新圖——與 LS-169 QA `5e37c5a2` 症狀
/// 逐位相同。修法：`avatarCacheBust` 與 `avatarSignedURLs` 改在同一段沒有中間 `await` 的
/// 程式碼裡一起寫入，`avatarURL(for:)` 對一次上傳因此只會改變一次。
///
/// **`.id(avatarURL)` 不是修法，是被 merge-review R1 mutation 實測推翻的錯誤嘗試**：曾經
/// 一度以為問題在 view 層、在 `ChildAvatarView` 的 `AsyncImage` 加 `.id(avatarURL)` 逼
/// SwiftUI 整顆重建——但這會把「一次上傳連續變兩次值」的過渡態各自翻成一次身分重建，兩次
/// 緊接著的重建反而讓 `AsyncImage` 的下載 task 在發出 GET 之前就被下一次重建取消，模擬器
/// 實測第三次換照片會卡住超過 2 分鐘（見 handoff）。已完全還原（`ChildAvatarView.swift`
/// 對 `origin/development` 的 diff 為 0）。**未來任何想在這個元件加 `.id()`／強制身分重建
/// 的修法，都必須先確認 `avatarURL(for:)` 的上游狀態是原子寫入，否則會放大這個 race。**
@MainActor
final class ChildrenStoreAvatarListRefreshTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let childID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private func makeChild(
        id: UUID? = nil,
        name: String = "陳小安",
        birthday: Date = Date(timeIntervalSince1970: 0),
        avatarURL: String? = nil,
        deletedAt: Date? = nil
    ) -> Child {
        Child(
            id: id ?? childID,
            name: name,
            birthday: birthday,
            avatarURL: avatarURL,
            deletedAt: deletedAt,
            createdAt: Date()
        )
    }

    /// LS-169 QA `5e37c5a2` 的原始情境：`currentAvatarURL: nil`（這個孩子本來沒有頭像，在
    /// 編輯畫面第一次加照片，不是換掉既有頭像）。`updateChild` 成功後 `avatarURL(for:)`
    /// 應該立即從 nil 變成非 nil 且帶 `lsv`。
    ///
    /// i1（merge-review R1）訂正：這條測試單獨看**不是**本票 bug 的回歸測試——它只斷言
    /// 「最終狀態有簽名 URL 且帶 lsv」，這在 bug 修法之前就已經成立（reviewer mutation A
    /// 實測：把本票修法完整還原，這條測試依然綠）。真正釘住這個 bug 的是下面
    /// `test_updateChild_avatarURLStaysStableUntilSignedURLsArrive`。這條測試留著是因為它
    /// 覆蓋了「第一次加照片」（`currentAvatarURL: nil`）這個 `ChildrenStoreAvatarTests` 既有
    /// 測試沒覆蓋到的路徑（既有測試的 `currentAvatarURL` 一律從一開始就非 nil），仍有獨立
    /// 存在的價值，只是名字所暗示的「這就是回歸測試」需要更正。
    func test_updateChild_firstAvatarFromNilCurrentAvatarURL_avatarURLBecomesNonNilWithCacheBust() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/first.jpg"
        let child = makeChild(avatarURL: nil)
        let uploadService = StubChildAvatarUploadService()
        let uploadedChild = makeChild(avatarURL: path)
        stub.setListChildrenHandler { _ in [child] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        XCTAssertNil(store.avatarURL(for: child), "還沒上傳過，avatarURL(for:) 應該回 nil（顯示縮寫）")

        stub.setListChildrenHandler { _ in [uploadedChild] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=first")!] }
        uploadService.setUploadAvatarHandler { _, _, _ in path }
        stub.setUpdateChildHandler { _, _, _, _ in }

        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: nil, newAvatarImageData: Data([0x09])
        )

        XCTAssertTrue(success)
        let afterURL = store.avatarURL(for: uploadedChild)
        XCTAssertNotNil(afterURL, "第一次上傳成功後，同一個 store 呼叫應該立即能拿到簽名 URL")
        XCTAssertTrue(afterURL?.query?.contains("lsv=") ?? false, "第一次上傳也該帶 lsv cache-busting 參數")
    }

    /// M1（merge-review R1，配方由 reviewer 貼在 comment，本輪照樣實跑驗證）：這才是這個 bug
    /// 真正的回歸測試——探針掛在 `stub.setUpdateChildHandler`（也就是 `apiClient.updateChild`
    /// RPC 那個 await 點，正是「上傳已完成、簽名尚未發出」的中途點），觀察 `avatarURL(for:)`
    /// 在那一刻的值，斷言它**還沒變成過渡態**（沒有出現「舊 token＋新 lsv」這個指紋）。
    ///
    /// 自證（本機實跑，未留在 commit 裡）：
    /// - HEAD（本票修法）：綠。
    /// - mutation A（把本票修法完整還原——cache-bust 寫回上傳成功當下、`refreshAvatarSignedURLs`
    ///   不寫）：**紅**，訊息帶著過渡態指紋
    ///   `("Optional(…token=first&lsv=…)") is not equal to ("Optional(…token=first)")`，與
    ///   reviewer comment 貼的指紋逐字相符。
    /// - mutation C（保留 plumbing，只在 `avatarSignedURLs = signed` 與
    ///   `avatarCacheBust[freshAvatarPath] = …` 之間插入一行 `await Task.yield()`）：這個探針
    ///   在 mutation C 下仍是綠的——它掛在 `apiClient.updateChild` RPC callback，時序上發生在
    ///   那兩個寫入「之前」（`reloadChildrenList` 要等 `update_child` RPC 回來才會走到簽名
    ///   那一段），插在兩者「之間」的 `await` 因此不會被這個探針看到。**R2 訂正（merge-review
    ///   `dd323682`）**：mutation C **在單元測試層級是可以可靠守住的**——見下面
    ///   `test_updateChild_neverExposesIntermediateAvatarURL`（watcher 版），這條測試留著只是
    ///   因為它守的是 mutation A 這個更常見的回歸形狀，兩條測試互補，不是互相替代。
    func test_updateChild_avatarURLStaysStableUntilSignedURLsArrive() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/first.jpg"
        let child = makeChild(avatarURL: path)
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=first")!] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        let before = store.avatarURL(for: child)
        XCTAssertNotNil(before)

        let observed = OSAllocatedUnfairLock<URL?>(initialState: nil)
        uploadService.setUploadAvatarHandler { _, _, _ in path }
        stub.setUpdateChildHandler { _, _, _, _ in
            let mid = await MainActor.run { store.avatarURL(for: child) }
            observed.withLock { $0 = mid }
        }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=second")!] }

        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: path, newAvatarImageData: Data([0x09])
        )

        XCTAssertTrue(success)
        XCTAssertEqual(
            observed.withLock { $0 }, before,
            "上傳成功後、簽名回來前，avatarURL(for:) 不該先變成過渡值（新 cache-bust ＋ 舊簽名 URL）"
        )
        XCTAssertNotEqual(store.avatarURL(for: child), before, "最終應該換成新的簽名 URL")
    }

    /// R2（merge-review `dd323682`，配方由 reviewer 貼在 comment，本輪照樣實跑驗證）：
    /// mutation C（`avatarSignedURLs = signed` 與 `avatarCacheBust[freshAvatarPath] = …`
    /// 之間插入一個 `await`）的可靠守門法——`watcher` 本身是 `@MainActor`，在 `updateChild`
    /// 執行期間每次讓出主 actor 時就取樣一次 `avatarURL(for:)`，斷言整段期間看到的值只可能
    /// 落在 {上傳前, 最終} 這個集合裡。**為什麼不會 flaky-red**：正確的程式碼裡兩個寫入之間
    /// 沒有 `await`（不可觀測），`children = fetched` 也不改變這個路徑的值，所以
    /// `avatarURL(for:)` 在任何 suspension point 上都只可能是這兩個值之一，排程怎麼交錯都不
    /// 會誤紅；它的弱點只在「可能漏抓」的方向，漏抓不會造成假警報。**踩過的坑**：取樣讀值要放
    /// 在 `withLock` 之外——`withLock` 的閉包是 nonisolated，裡面直接呼叫 `store.avatarURL(for:)`
    /// 這個 `@MainActor` 方法編不過（"call to main actor-isolated instance method … in a
    /// synchronous nonisolated context"）；`watcher` 也刻意保持 `@MainActor`（不要改寫成非
    /// `@MainActor` 再用 `await MainActor.run { … }` 跳轉取樣——那會讓每次取樣變成一個新排入
    /// 的 job，未必落在那個 yield 窗口裡，是 R2 猜測 R1 那版失敗的原因）。i4：
    /// `XCTAssertGreaterThan(samples.count, 0)` 防哪天流程變成沒有 suspension point、watcher
    /// 一次都沒取到樣、測試靜默退化成 no-op 卻永遠綠。
    ///
    /// 自證（本機實跑，未留在 commit 裡）：HEAD 上連跑 5 次全綠；在 scratchpad 複本上套
    /// mutation C 連跑 3 次全紅，紅訊息＋取樣細節見 handoff。
    func test_updateChild_neverExposesIntermediateAvatarURL() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/first.jpg"
        let child = makeChild(avatarURL: path)
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=first")!] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        let before = store.avatarURL(for: child)?.absoluteString ?? "nil"

        uploadService.setUploadAvatarHandler { _, _, _ in path }
        stub.setUpdateChildHandler { _, _, _, _ in }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=second")!] }

        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let done = OSAllocatedUnfairLock<Bool>(initialState: false)
        // watcher 自己就是 @MainActor：`updateChild` 每次讓出主 actor 時它就取樣一次。
        // 取樣要在 withLock 之外讀（withLock 的閉包是 nonisolated，裡面呼叫 @MainActor 方法編不過）。
        let watcher = Task { @MainActor in
            while !done.withLock({ $0 }) {
                let sample = store.avatarURL(for: child)?.absoluteString ?? "nil"
                seen.withLock { $0.append(sample) }
                await Task.yield()
            }
        }

        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: path, newAvatarImageData: Data([0x09])
        )
        done.withLock { $0 = true }
        _ = await watcher.value

        let after = store.avatarURL(for: child)?.absoluteString ?? "nil"
        let samples = seen.withLock { $0 }
        XCTAssertTrue(success)
        XCTAssertGreaterThan(samples.count, 0, "watcher 一次都沒取到樣＝這條測試已退化成 no-op")
        XCTAssertTrue(
            Set(samples).subtracting([before, after]).isEmpty,
            "一次上傳期間出現了過渡值：\(Set(samples).subtracting([before, after]))——" +
                "`avatarCacheBust` 與 `avatarSignedURLs` 之間出現了 suspension point"
        )
    }
}
