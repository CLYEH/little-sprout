import Foundation
@testable import LittleSprout
import XCTest

/// LS-192：02 顯示名稱與頭像編輯——`FamilyStore+Profile.swift` 的狀態機測試，拆檔理由同
/// `FamilyStoreMembersTests` 的既有說明。
@MainActor
final class FamilyStoreProfileTests: XCTestCase {
    private let familyID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let myID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    /// SwiftLint `large_tuple`（>2 members）擋掉裸 tuple，同 `StubFamilyAPIClient.CreateInviteCall`
    /// 的既有理由改用具名 struct。
    private struct TestStore {
        let store: FamilyStore
        let stub: StubFamilyAPIClient
        let avatarService: StubChildAvatarUploadService
    }

    private func makeStore() -> TestStore {
        let stub = StubFamilyAPIClient()
        let avatarService = StubChildAvatarUploadService()
        let store = FamilyStore(apiClient: stub, avatarUploadService: avatarService)
        return TestStore(store: store, stub: stub, avatarService: avatarService)
    }

    private func makeProfile(displayName: String = "陳美玲", avatarURL: String? = nil) -> Profile {
        Profile(id: myID, displayName: displayName, avatarURL: avatarURL)
    }

    // MARK: - refreshProfile

    func test_refreshProfile_success_populatesMyProfile() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        let profile = makeProfile()
        stub.setFetchMyProfileHandler { profile }

        let result = await store.refreshProfile()

        XCTAssertEqual(result, profile)
        XCTAssertEqual(store.myProfile, profile)
        XCTAssertEqual(store.profileState, .success)
    }

    func test_refreshProfile_failure_setsFailureState() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        stub.setFetchMyProfileHandler { throw AppError.server(message: "boom", code: nil) }

        _ = await store.refreshProfile()

        guard case .failure = store.profileState else {
            return XCTFail("查詢失敗應該落 .failure，讓 ProfileEditView 顯示錯誤")
        }
        XCTAssertNil(store.myProfile)
    }

    // MARK: - updateDisplayName

    func test_updateDisplayName_success_updatesMyProfileAndCallsHandlerWithTrimmedValue() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        let myID = self.myID
        stub.setUpdateDisplayNameHandler { name in Profile(id: myID, displayName: name, avatarURL: nil) }

        let success = await store.updateDisplayName("陳小華")

        XCTAssertTrue(success)
        XCTAssertEqual(store.myProfile?.displayName, "陳小華")
        XCTAssertEqual(store.updateDisplayNameState, .success)
        XCTAssertEqual(stub.updateDisplayNameCalls, ["陳小華"])
    }

    func test_updateDisplayName_failure_setsFailureState_doesNotTouchMyProfile() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        store.seedProfileForPreview(makeProfile(displayName: "原本的名字"))
        stub.setUpdateDisplayNameHandler { _ in
            throw AppError.validationRetryable(message: "太長了", code: "23514")
        }

        let success = await store.updateDisplayName("超過五十個字的一個非常非常非常長的名字")

        XCTAssertFalse(success)
        XCTAssertEqual(store.myProfile?.displayName, "原本的名字", "更新失敗不該覆寫畫面上原本顯示的名字")
        guard case .failure = store.updateDisplayNameState else {
            return XCTFail("更新失敗應該落 .failure")
        }
    }

    // MARK: - updateAvatar

    /// `updateAvatar` 需要 `ownerUserID`（透過 `syncOwner(to:)` 設定，見
    /// `FamilyStoreMembersTests.test_leaveFamily_success_clearsMyFamilyAndMembers` 同一個
    /// 既有理由——`private(set)`，沒有對應的 `#if DEBUG` seed 入口）。
    func test_updateAvatar_success_uploadsThenWritesPath_andSetsCacheBust() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        let avatarService = context.avatarService
        let familyID = self.familyID
        let myID = self.myID
        stub.setFetchMyFamilyHandler {
            Family(id: familyID, name: "陳家", createdBy: myID, createdAt: Date(), requireApproval: true)
        }
        await store.syncOwner(to: myID)
        avatarService.setUploadAvatarHandler { familyID, userID, _ in
            "\(familyID.uuidString.lowercased())/avatars/\(userID.uuidString.lowercased()).jpg"
        }
        let expectedPath = "\(familyID.uuidString.lowercased())/avatars/\(myID.uuidString.lowercased()).jpg"
        stub.setUpdateAvatarPathHandler { path in Profile(id: myID, displayName: "陳美玲", avatarURL: path) }

        let success = await store.updateAvatar(familyID: familyID, imageData: Data([0x01]))

        XCTAssertTrue(success)
        XCTAssertEqual(store.myProfile?.avatarURL, expectedPath)
        XCTAssertEqual(store.updateAvatarState, .success)
        XCTAssertEqual(avatarService.calls.first?.familyID, familyID)
        XCTAssertEqual(avatarService.calls.first?.childID, myID, "頭像上傳用呼叫者自己的 userID 當路徑最後一段")
        XCTAssertEqual(stub.updateAvatarPathCalls, [expectedPath])
        XCTAssertNotNil(store.avatarCacheBust[expectedPath], "換頭像成功後應該記一個 cache-bust 時間戳（LS-174 同型）")
    }

    func test_updateAvatar_uploadFailure_setsFailureState_doesNotWritePath() async {
        let context = makeStore()
        let store = context.store
        let stub = context.stub
        let avatarService = context.avatarService
        let familyID = self.familyID
        let myID = self.myID
        stub.setFetchMyFamilyHandler {
            Family(id: familyID, name: "陳家", createdBy: myID, createdAt: Date(), requireApproval: true)
        }
        await store.syncOwner(to: myID)
        avatarService.setUploadAvatarHandler { _, _, _ in
            throw AppError.rejected(message: "這張照片沒辦法使用", code: nil)
        }

        let success = await store.updateAvatar(familyID: familyID, imageData: Data([0x01]))

        XCTAssertFalse(success)
        XCTAssertEqual(stub.updateAvatarPathCalls, [], "上傳失敗不該接著呼叫 updateAvatarPath")
        guard case .failure = store.updateAvatarState else {
            return XCTFail("上傳失敗應該落 .failure")
        }
    }

    // MARK: - avatarDisplayURL

    func test_avatarDisplayURL_nilRawValue_returnsNil() {
        let store = makeStore().store
        XCTAssertNil(store.avatarDisplayURL(rawValue: nil))
    }

    /// OAuth 提供的公開頭像網址（`https://` 開頭）——直接回傳，不查 `avatarSignedURLs`。
    func test_avatarDisplayURL_oauthURL_returnsDirectly() {
        let store = makeStore().store
        let result = store.avatarDisplayURL(rawValue: "https://lh3.googleusercontent.com/a/avatar.jpg")
        XCTAssertEqual(result, URL(string: "https://lh3.googleusercontent.com/a/avatar.jpg"))
    }

    /// Storage 路徑但簽名還沒回來——回 nil，呼叫端退回縮寫（同 `ChildrenStore.avatarURL(for:)`）。
    func test_avatarDisplayURL_storagePathNotYetSigned_returnsNil() {
        let store = makeStore().store
        let path = "\(familyID.uuidString.lowercased())/avatars/\(myID.uuidString.lowercased()).jpg"
        XCTAssertNil(store.avatarDisplayURL(rawValue: path))
    }

    /// Storage 路徑已簽名、且有 cache-bust 記錄——回傳的 URL 應該疊加 `lsv` 查詢參數。
    func test_avatarDisplayURL_storagePathSignedWithCacheBust_appendsQueryParam() {
        let store = makeStore().store
        let path = "\(familyID.uuidString.lowercased())/avatars/\(myID.uuidString.lowercased()).jpg"
        let signed = URL(string: "https://example.supabase.co/storage/v1/object/sign/media/\(path)?token=abc")!
        store.avatarSignedURLs[path] = signed
        store.avatarCacheBust[path] = 1_700_000_000

        let result = store.avatarDisplayURL(rawValue: path)

        XCTAssertNotNil(result)
        let query = result?.query ?? "nil"
        XCTAssertTrue(query.contains("lsv=1700000000.0"), "應疊加 lsv cache-bust 參數，實際：\(query)")
    }

    // MARK: - ProfileAvatarPath.isStoragePath

    func test_isStoragePath_httpsURL_false() {
        XCTAssertFalse(ProfileAvatarPath.isStoragePath("https://lh3.googleusercontent.com/a/avatar.jpg"))
    }

    func test_isStoragePath_storagePath_true() {
        let path = "\(familyID.uuidString.lowercased())/avatars/\(myID.uuidString.lowercased()).jpg"
        XCTAssertTrue(ProfileAvatarPath.isStoragePath(path))
    }
}
