import Foundation
@testable import LittleSprout
import XCTest

/// `ChildrenStore` 頭像上傳編排（LS-169）：`createChild`／`updateChild` 何時呼叫
/// `ChildAvatarUploadService`、上傳結果如何餵回 `update_child`、上傳失敗時的回滾語意。
/// 從 `ChildrenStoreTests` 拆出獨立檔案——加完這批測試後那支檔案超過 SwiftLint
/// `file_length`／`type_body_length` 上限，理由同 `DiaryComposerStorePublishRetryTests`
/// 從 `DiaryComposerStorePublishTests` 拆分（見該檔文件註解）。
@MainActor
final class ChildrenStoreAvatarTests: XCTestCase {
    private let familyID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let childID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private func makeChild(
        id: UUID? = nil,
        name: String = "陳小安",
        birthday: Date = Date(timeIntervalSince1970: 0),
        deletedAt: Date? = nil
    ) -> Child {
        Child(
            id: id ?? childID,
            name: name,
            birthday: birthday,
            avatarURL: nil,
            deletedAt: deletedAt,
            createdAt: Date()
        )
    }

    // MARK: - createChild + avatar

    /// 票文 Scope 1「建檔時先 create_child 取 id 再上傳＋update_child」：三個呼叫要依序發生，
    /// 且第二階段的 `update_child` 要帶上傳回來的路徑，不是原封不動的 nil。
    func test_createChild_withAvatarImageData_createsThenUploadsThenUpdatesWithPath() async {
        let stub = StubChildAPIClient()
        let created = makeChild()
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [created] }
        stub.setCreateChildHandler { _, _, _, avatarURL in
            XCTAssertNil(avatarURL, "create_child 那一步不該帶頭像路徑——頭像要等 id 存在才能上傳")
            return created.id
        }
        uploadService.setUploadAvatarHandler { _, _, _ in "fake/avatars/path.jpg" }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        let imageData = Data([0x01, 0x02, 0x03])

        let success = await store.createChild(name: "陳小安", birthday: Date(), avatarImageData: imageData)

        XCTAssertTrue(success)
        XCTAssertEqual(uploadService.calls.count, 1)
        XCTAssertEqual(uploadService.calls.first?.familyID, familyID)
        XCTAssertEqual(uploadService.calls.first?.childID, created.id)
        XCTAssertEqual(uploadService.calls.first?.imageData, imageData)
        XCTAssertEqual(stub.updateChildCalls.last?.avatarURL, "fake/avatars/path.jpg")
    }

    /// 失敗回滾語意（票文 Scope 1）：`create_child` 已成功時，頭像上傳失敗不會讓孩子檔案
    /// 消失（沒有硬刪路徑），但整體回傳 false；重試（同一個畫面實例、沒有呼叫
    /// `resetCreateState()`）不會再呼叫一次 `create_child`——否則會建出兩筆同名孩子。
    func test_createChild_avatarUploadFailure_keepsCreatedChild_retryDoesNotDuplicateCreate() async {
        let stub = StubChildAPIClient()
        let created = makeChild()
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [created] }
        stub.setCreateChildHandler { _, _, _, _ in created.id }
        uploadService.setUploadAvatarHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        let imageData = Data([0x01])

        let firstAttempt = await store.createChild(name: "陳小安", birthday: Date(), avatarImageData: imageData)
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(stub.createChildCalls.count, 1)

        // 重試：頭像上傳這次成功，應該沿用第一次已建立的 childID，不再呼叫一次 create_child。
        uploadService.setUploadAvatarHandler { _, _, _ in "fake/avatars/path.jpg" }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let secondAttempt = await store.createChild(name: "陳小安", birthday: Date(), avatarImageData: imageData)

        XCTAssertTrue(secondAttempt)
        XCTAssertEqual(stub.createChildCalls.count, 1, "重試不該再呼叫一次 create_child，會建出重複的孩子")
        XCTAssertEqual(stub.updateChildCalls.last?.childID, created.id)
    }

    /// `resetCreateState()` 由畫面 `onAppear` 呼叫，代表「重新進入這個畫面」——這時應該清掉
    /// 上一次失敗殘留的 `pendingCreateChildID`，下一次建立要是全新的一筆，不能沿用舊 id
    /// （否則會把新輸入的名字／生日誤寫進一個使用者已經放棄的舊孩子檔案）。
    func test_resetCreateState_clearsPendingChildID_nextCreateStartsFresh() async {
        let stub = StubChildAPIClient()
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [] }
        stub.setCreateChildHandler { _, _, _, _ in UUID() }
        uploadService.setUploadAvatarHandler { _, _, _ in throw AppError.network(message: "offline") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        _ = await store.createChild(name: "陳小安", birthday: Date(), avatarImageData: Data([0x01]))
        XCTAssertEqual(stub.createChildCalls.count, 1)

        store.resetCreateState()
        _ = await store.createChild(name: "陳小軒", birthday: Date(), avatarImageData: Data([0x02]))

        XCTAssertEqual(stub.createChildCalls.count, 2, "resetCreateState 之後應該視為全新一次建立")
    }

    // MARK: - updateChild + avatar

    /// 換照片：先上傳新頭像，成功才帶新路徑（不是呼叫端傳進來的 `currentAvatarURL`）呼叫
    /// `update_child`。
    func test_updateChild_withNewAvatarImageData_uploadsThenUpdatesWithNewPath() async {
        let stub = StubChildAPIClient()
        let updated = makeChild(name: "陳小安")
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [updated] }
        uploadService.setUploadAvatarHandler { _, _, _ in "fake/avatars/new.jpg" }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        let imageData = Data([0x09])

        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: "fake/avatars/old.jpg", newAvatarImageData: imageData
        )

        XCTAssertTrue(success)
        XCTAssertEqual(uploadService.calls.count, 1)
        XCTAssertEqual(uploadService.calls.first?.childID, childID)
        XCTAssertEqual(uploadService.calls.first?.imageData, imageData)
        XCTAssertEqual(stub.updateChildCalls.last?.avatarURL, "fake/avatars/new.jpg")
    }

    /// 上傳失敗時整段不呼叫 `update_child`——保留原有的 `currentAvatarURL`（同「編輯情境下
    /// 保留原圖」的精神，見 `ChildrenStore.updateChild` 文件註解）。
    func test_updateChild_avatarUploadFailure_doesNotCallUpdateChild() async {
        let stub = StubChildAPIClient()
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [] }
        uploadService.setUploadAvatarHandler { _, _, _ in throw AppError.network(message: "offline") }
        stub.setUpdateChildHandler { _, _, _, _ in XCTFail("上傳失敗不該還呼叫 update_child") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)

        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: "fake/avatars/old.jpg", newAvatarImageData: Data([0x09])
        )

        XCTAssertFalse(success)
        XCTAssertTrue(stub.updateChildCalls.isEmpty)
        guard case .failure = store.updateState else {
            return XCTFail("應該落 failure")
        }
    }
}
