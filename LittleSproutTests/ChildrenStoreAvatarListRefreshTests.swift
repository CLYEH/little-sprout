import Foundation
@testable import LittleSprout
import XCTest

/// LS-174：儲存寶貝頭像後回到寶貝管理列表不即時刷新——找根因排查釘住的情境。從
/// `ChildrenStoreAvatarTests` 拆出獨立檔案——加完這條測試後那支檔案超過 SwiftLint
/// `type_body_length` 上限，理由同該檔文件註解「從 `ChildrenStoreTests` 拆出」的先例。
///
/// 找根因結論（詳見 handoff）：`ChildrenStore.updateChild`／`createChild` 在 LS-169 R2
/// （`avatarCacheBust`）與 LS-173 之後，成功時已經在回傳 `true` 之前 `await
/// reloadChildrenList()` 完整跑完——`children`、`avatarSignedURLs`、`avatarCacheBust`
/// 三者都會在呼叫端（`EditChildView.submit()`／`CreateChildView` 對應方法）拿到 `success`
/// 並呼叫 `dismiss()` 之前更新完畢，store 這一層沒有邏輯缺陷。這條測試釘住的正是 LS-169 QA
/// `5e37c5a2` 回報的原始情境——不是「換掉既有頭像」（`ChildrenStoreAvatarTests` 既有測試
/// `test_updateChild_withNewAvatarImageData_avatarURLGainsCacheBustAfterUpload_...` 用的
/// `currentAvatarURL` 從一開始就非 nil），而是「這個孩子本來沒有頭像，在編輯畫面（09b，不是
/// 建檔 08）第一次加照片」——`currentAvatarURL: nil`。
///
/// 真正的最小修法落在 view 層：`ChildAvatarView` 的 `AsyncImage` 加 `.id(avatarURL)`，逼
/// SwiftUI 在 URL 變了的時候整顆重建、不依賴 `AsyncImage` 自行偵測 URL 變化這件沒有文件保證
/// 的行為（見該檔文件註解）——這條 store 層測試證明「資料本身已經正確」，不表示 view 層沒有
/// 需要修的地方。
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

    /// mutation 證據（見 handoff）：拿掉 `ChildrenStore.updateChild` 成功路徑裡的
    /// `await reloadChildrenList()` 這一行，這條測試會紅（`avatarSignedURLs` 拿不到新路徑的
    /// 簽名 URL，`afterURL` 是 nil）——沒有留在 commit 裡，僅本機驗證過。
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
}
