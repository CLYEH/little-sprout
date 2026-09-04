import Foundation
@testable import LittleSprout
import os
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

    // MARK: - createChild + avatar

    /// 票文 Scope 1「建檔時先 create_child 取 id 再上傳＋update_child」：三個呼叫要依序發生，
    /// 且第二階段的 `update_child` 要帶上傳回來的路徑，不是原封不動的 nil。
    func test_createChild_withAvatarImageData_createsThenUploadsThenUpdatesWithPath() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/path.jpg"
        let created = makeChild(avatarURL: path)
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [created] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=new")!] }
        stub.setCreateChildHandler { _, _, _, avatarURL in
            XCTAssertNil(avatarURL, "create_child 那一步不該帶頭像路徑——頭像要等 id 存在才能上傳")
            return created.id
        }
        uploadService.setUploadAvatarHandler { _, _, _ in path }
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
        XCTAssertEqual(stub.updateChildCalls.last?.avatarURL, path)
        // merge-review R1 n1（8b477108）：建檔路徑的 avatarCacheBust 寫入（ChildrenStore.swift:151）
        // 先前沒有任何測試釘住——只驗到 update_child 帶對路徑，沒驗到 avatarURL(for:) 真的帶 lsv。
        XCTAssertTrue(
            store.avatarURL(for: created)?.query?.contains("lsv=") ?? false,
            "建檔時上傳頭像也應該帶 lsv cache-busting 參數，跟換照片（updateChild）同一個機制"
        )
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

    // MARK: - avatarURL(for:) / refreshAvatarSignedURLs（i1，merge-review R1）

    /// `refresh` 之後，有 `avatarURL` 的孩子應該能透過 `avatarURL(for:)` 取得簽名 URL。
    func test_refresh_childHasAvatarURL_avatarURLForChild_returnsSignedURL() async {
        let stub = StubChildAPIClient()
        let child = makeChild(avatarURL: "fake/avatars/path.jpg")
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { paths in
            XCTAssertEqual(paths, ["fake/avatars/path.jpg"])
            return ["fake/avatars/path.jpg": URL(string: "https://example.test/signed?token=abc")!]
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(store.avatarURL(for: child)?.absoluteString.hasPrefix("https://example.test/signed"), true)
    }

    /// 沒有孩子帶 `avatarURL` 時不該打簽名 URL 的網路——`signedAvatarURLs` 完全不該被呼叫。
    func test_refresh_noChildHasAvatarURL_doesNotCallSignedAvatarURLs() async {
        let stub = StubChildAPIClient()
        let child = makeChild(avatarURL: nil)
        stub.setListChildrenHandler { _ in [child] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.refresh(familyID: familyID)

        XCTAssertTrue(stub.signedAvatarURLsCalls.isEmpty, "沒有任何 avatarURL 時不該打網路簽名")
        XCTAssertNil(store.avatarURL(for: child))
    }

    /// 簽名失敗（例如網路問題）時保留舊值，不整批清空——同 `refreshAvatarSignedURLs`
    /// 文件註解「簽名本身失敗不當成整體失敗」。
    func test_refresh_signingFails_keepsPreviousSignedURLs() async {
        let stub = StubChildAPIClient()
        let child = makeChild(avatarURL: "fake/avatars/path.jpg")
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in
            ["fake/avatars/path.jpg": URL(string: "https://example.test/signed?token=first")!]
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)
        let firstURL = store.avatarURL(for: child)
        XCTAssertNotNil(firstURL)

        stub.setSignedAvatarURLsHandler { _ in throw AppError.network(message: "offline") }
        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(store.avatarURL(for: child), firstURL, "簽名失敗應該保留上一次成功的結果")
    }

    // MARK: - avatarCacheBust（LS-169 R2 i8，LS-173 補測）

    /// 換照片後，`avatarURL(for:)` 應該多帶一個 `lsv` cache-busting 查詢參數、且跟上傳前的
    /// URL 不同——這正是「換圖後列表立即更新」的機制（見 `ChildrenStore.avatarCacheBust`
    /// 文件註解）。還沒有這個 client 自己上傳過的路徑（`avatarCacheBust` 沒有這個 key）不該
    /// 帶 `lsv`，直接沿用原始簽名 URL。
    func test_updateChild_withNewAvatarImageData_avatarURLGainsCacheBustAfterUpload_differsFromBeforeUpload() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/path.jpg"
        let child = makeChild(avatarURL: path)
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=abc")!] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)

        let beforeUploadURL = store.avatarURL(for: child)
        XCTAssertEqual(
            beforeUploadURL?.query, "token=abc", "還沒有這個 client 自己上傳過，不該帶 lsv cache-busting 參數"
        )

        uploadService.setUploadAvatarHandler { _, _, _ in path }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let success = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: path, newAvatarImageData: Data([0x09])
        )
        XCTAssertTrue(success)

        let afterUploadURL = store.avatarURL(for: child)
        XCTAssertNotEqual(afterUploadURL, beforeUploadURL, "換圖後 URL 應該變，讓 AsyncImage 重抓")
        XCTAssertTrue(afterUploadURL?.query?.contains("lsv=") ?? false, "上傳成功後應該帶 lsv cache-busting 參數")
    }

    /// 「render 不現算」：`avatarCacheBust` 是上傳成功當下寫一次的固定時間戳，不是
    /// `avatarURL(for:)` 每次呼叫都用 `Date()` 現算——同一次 session 內連續呼叫兩次應該回傳
    /// 完全相同的值。
    func test_avatarURL_calledTwiceAfterUpload_returnsIdenticalCacheBustValue() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/path.jpg"
        let child = makeChild(avatarURL: path)
        let uploadService = StubChildAvatarUploadService()
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=abc")!] }
        uploadService.setUploadAvatarHandler { _, _, _ in path }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: uploadService)
        _ = await store.refresh(familyID: familyID)
        _ = await store.updateChild(
            childID: childID, name: "陳小安", birthday: Date(),
            currentAvatarURL: path, newAvatarImageData: Data([0x09])
        )

        let first = store.avatarURL(for: child)
        let second = store.avatarURL(for: child)

        XCTAssertEqual(first, second, "同一次 session 呼叫兩次應該回傳同一個值，不是即時運算的新時間戳")
    }

    /// 「未上傳者無 key」：從沒有經過這個 client 上傳流程的孩子（`avatarURL` 是伺服器既有值，
    /// `avatarCacheBust` 從沒寫過這個路徑），`avatarURL(for:)` 不該帶 `lsv`。
    func test_avatarURL_pathNeverUploadedThisSession_hasNoCacheBustQueryParam() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/never-uploaded.jpg"
        let child = makeChild(avatarURL: path)
        stub.setListChildrenHandler { _ in [child] }
        stub.setSignedAvatarURLsHandler { _ in [path: URL(string: "https://example.test/signed?token=xyz")!] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.refresh(familyID: familyID)

        let url = store.avatarURL(for: child)
        XCTAssertEqual(url?.absoluteString, "https://example.test/signed?token=xyz")
        XCTAssertFalse(url?.query?.contains("lsv") ?? true)
    }

    // MARK: - refreshAvatarSignedURLs 世代守門（m2，LS-169 R1；LS-173 i10 補測）

    /// 票文情境「兩個簽名 handler、後發先至」：第一次 `refresh` 的簽名請求卡住還沒回來，
    /// 使用者已經觸發第二次 `refresh`（例如還原一個孩子）並先拿到回應——較舊的那次遲到回來
    /// 時，不能覆蓋較新一次已經寫入 `avatarSignedURLs` 的結果（見 `refreshAvatarSignedURLs`
    /// 文件註解「m2」）。
    func test_refresh_staleSignedURLResponseArrivesAfterNewerRefresh_doesNotOverwriteNewerResult() async {
        let stub = StubChildAPIClient()
        let path = "fake/avatars/path.jpg"
        let child = makeChild(avatarURL: path)
        stub.setListChildrenHandler { _ in [child] }
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        stub.setSignedAvatarURLsHandler { _ in
            let index = callCount.withLock { $0 += 1; return $0 }
            if index == 1 {
                var iterator = gate.makeAsyncIterator()
                _ = await iterator.next()
                return [path: URL(string: "https://example.test/signed?token=STALE")!]
            }
            return [path: URL(string: "https://example.test/signed?token=FRESH")!]
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let firstRefresh = Task { await store.refresh(familyID: familyID) }
        var guardIterations = 0
        while callCount.withLock({ $0 }) < 1 {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待第一次簽名請求進入處理中逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // 第二次 refresh：立即拿到簽名回應，此時第一次仍卡在 gate 上。
        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(
            store.avatarURL(for: child)?.query, "token=FRESH", "新一輪的簽名結果應該先寫入"
        )

        gateContinuation.finish()
        _ = await firstRefresh.value

        XCTAssertEqual(
            store.avatarURL(for: child)?.query, "token=FRESH", "較舊的呼叫遲到不能覆蓋新結果"
        )
    }
}
