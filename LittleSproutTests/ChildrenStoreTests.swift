import Foundation
@testable import LittleSprout
import os
import XCTest

/// `ChildrenStore` 狀態機（idle／submitting／success／failure(AppError)）＋衍生角色旗標
/// （`isOwner`／`canManageChildren`）：09 管理／09b 編輯／09c 刪除確認／10 切換器都依這裡的
/// 狀態直接重繪，見該檔文件註解。頭像上傳編排（LS-169）另見 `ChildrenStoreAvatarTests`。
@MainActor
final class ChildrenStoreTests: XCTestCase {
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

    // MARK: - refresh

    func test_refresh_success_setsChildrenAndRole() async {
        let stub = StubChildAPIClient()
        let child = makeChild()
        stub.setListChildrenHandler { _ in [child] }
        stub.setFetchMyRoleHandler { _ in .member }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let result = await store.refresh(familyID: familyID)

        XCTAssertEqual(result, [child])
        XCTAssertEqual(store.children, [child])
        XCTAssertEqual(store.myRole, .member)
        XCTAssertEqual(store.listState, .success)
    }

    func test_refresh_failure_setsFailureState() async {
        let stub = StubChildAPIClient()
        stub.setListChildrenHandler { _ in throw AppError.network(message: "offline") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(store.listState, .failure(.network(message: "offline")))
    }

    func test_refresh_whileSubmitting_ignoresDuplicateCall() async {
        let stub = StubChildAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setListChildrenHandler { _ in
            callCount.withLock { $0 += 1 }
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return []
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let firstCallTask = Task { await store.refresh(familyID: familyID) }
        var guardIterations = 0
        while store.listState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 listState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(stub.listChildrenCallCount, 1, "底層 API 只該被呼叫一次")

        gateContinuation.finish()
        _ = await firstCallTask.value
    }

    // MARK: - activeChildren / removedChildren / role flags

    func test_activeAndRemovedChildren_splitByDeletedAt() async {
        let stub = StubChildAPIClient()
        let active = makeChild(id: UUID(), name: "陳小安")
        let removed = makeChild(id: UUID(), name: "陳小軒", deletedAt: Date())
        stub.setListChildrenHandler { _ in [active, removed] }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        _ = await store.refresh(familyID: familyID)

        XCTAssertEqual(store.activeChildren, [active])
        XCTAssertEqual(store.removedChildren, [removed])
    }

    func test_roleFlags_reflectMyRole() async {
        let stub = StubChildAPIClient()
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        stub.setFetchMyRoleHandler { _ in .owner }
        _ = await store.refresh(familyID: familyID)
        XCTAssertTrue(store.isOwner)
        XCTAssertTrue(store.canManageChildren)

        stub.setFetchMyRoleHandler { _ in .member }
        _ = await store.refresh(familyID: familyID)
        XCTAssertFalse(store.isOwner)
        XCTAssertTrue(store.canManageChildren)

        stub.setFetchMyRoleHandler { _ in .viewer }
        _ = await store.refresh(familyID: familyID)
        XCTAssertFalse(store.isOwner)
        XCTAssertFalse(store.canManageChildren)
    }

    // MARK: - createChild

    func test_createChild_success_reloadsList() async {
        let stub = StubChildAPIClient()
        let created = makeChild()
        stub.setListChildrenHandler { _ in [created] }
        stub.setCreateChildHandler { _, _, _, _ in created.id }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)

        let success = await store.createChild(name: "陳小安", birthday: Date())

        XCTAssertTrue(success)
        XCTAssertEqual(store.createState, .success)
        XCTAssertEqual(store.children, [created])
    }

    func test_createChild_withoutFamilyID_returnsFalseWithoutCallingAPI() async {
        let stub = StubChildAPIClient()
        let wasCalled = OSAllocatedUnfairLock(initialState: false)
        stub.setCreateChildHandler { _, _, _, _ in
            wasCalled.withLock { $0 = true }
            return UUID()
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let success = await store.createChild(name: "陳小安", birthday: Date())

        XCTAssertFalse(success)
        XCTAssertFalse(wasCalled.withLock { $0 })
        guard case .failure = store.createState else {
            return XCTFail("沒有 familyID 應該落 failure")
        }
    }

    func test_createChild_apiFailure_setsFailureState() async {
        let stub = StubChildAPIClient()
        stub.setListChildrenHandler { _ in [] }
        stub.setCreateChildHandler { _, _, _, _ in throw AppError.validationRetryable(message: "壞的生日", code: "23502") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)

        let success = await store.createChild(name: "陳小安", birthday: Date())

        XCTAssertFalse(success)
        XCTAssertEqual(store.createState, .failure(.validationRetryable(message: "壞的生日", code: "23502")))
    }

    func test_resetCreateState_onlyClearsFailure() async {
        let stub = StubChildAPIClient()
        stub.setCreateChildHandler { _, _, _, _ in throw AppError.server(message: "boom", code: nil) }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)
        _ = await store.createChild(name: "陳小安", birthday: Date())
        guard case .failure = store.createState else {
            return XCTFail("前置條件：應該是 failure")
        }

        store.resetCreateState()

        XCTAssertEqual(store.createState, .idle)
    }

    // MARK: - updateChild

    func test_updateChild_success_reloadsListAndRecordsCall() async {
        let stub = StubChildAPIClient()
        let updated = makeChild(name: "陳小安改名")
        stub.setListChildrenHandler { _ in [updated] }
        stub.setUpdateChildHandler { _, _, _, _ in }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)
        let birthday = Date(timeIntervalSince1970: 1_000_000)

        let success = await store.updateChild(
            childID: childID, name: "陳小安改名", birthday: birthday, currentAvatarURL: nil
        )

        XCTAssertTrue(success)
        XCTAssertEqual(store.updateState, .success)
        XCTAssertEqual(store.children, [updated])
        XCTAssertEqual(stub.updateChildCalls, [
            .init(childID: childID, name: "陳小安改名", birthday: birthday, avatarURL: nil)
        ])
    }

    func test_updateChild_failure_setsFailureState() async {
        let stub = StubChildAPIClient()
        stub.setUpdateChildHandler { _, _, _, _ in throw AppError.rejected(message: "不是成員", code: "LS042") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let success = await store.updateChild(childID: childID, name: "x", birthday: Date(), currentAvatarURL: nil)

        XCTAssertFalse(success)
        XCTAssertEqual(store.updateState, .failure(.rejected(message: "不是成員", code: "LS042")))
    }

    // MARK: - setChildDeleted

    func test_setChildDeleted_softDelete_success_reloadsListAndRecordsCall() async {
        let stub = StubChildAPIClient()
        let deletedChild = makeChild(deletedAt: Date())
        stub.setListChildrenHandler { _ in [deletedChild] }
        stub.setSetChildDeletedHandler { _, _ in }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)

        let success = await store.setChildDeleted(childID: childID, deleted: true)

        XCTAssertTrue(success)
        XCTAssertEqual(store.deleteState, .success)
        XCTAssertEqual(store.removedChildren, [deletedChild])
        XCTAssertEqual(stub.setChildDeletedCalls, [.init(childID: childID, deleted: true)])
    }

    func test_setChildDeleted_restoreWindowExpired_setsFailureState() async {
        let stub = StubChildAPIClient()
        stub.setSetChildDeletedHandler { _, _ in throw AppError.rejected(message: "超過 30 天", code: "LS043") }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let success = await store.setChildDeleted(childID: childID, deleted: false)

        XCTAssertFalse(success)
        XCTAssertEqual(store.deleteState, .failure(.rejected(message: "超過 30 天", code: "LS043")))
    }

    func test_setChildDeleted_whileSubmitting_ignoresDuplicateCall() async {
        let stub = StubChildAPIClient()
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        stub.setSetChildDeletedHandler { _, _ in
            callCount.withLock { $0 += 1 }
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())

        let firstCallTask = Task { await store.setChildDeleted(childID: childID, deleted: true) }
        var guardIterations = 0
        while store.deleteState != .submitting {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待 deleteState 進入 .submitting 逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let secondResult = await store.setChildDeleted(childID: childID, deleted: true)

        XCTAssertFalse(secondResult)
        XCTAssertEqual(stub.setChildDeletedCalls.count, 1, "底層 API 只該被呼叫一次")

        gateContinuation.finish()
        _ = await firstCallTask.value
    }

    // MARK: - reset

    func test_reset_clearsEverything() async {
        let stub = StubChildAPIClient()
        let child = makeChild()
        stub.setListChildrenHandler { _ in [child] }
        stub.setFetchMyRoleHandler { _ in .owner }
        let store = ChildrenStore(apiClient: stub, avatarUploadService: StubChildAvatarUploadService())
        _ = await store.refresh(familyID: familyID)
        XCTAssertFalse(store.children.isEmpty)

        store.reset()

        XCTAssertTrue(store.children.isEmpty)
        XCTAssertNil(store.myRole)
        XCTAssertEqual(store.listState, .idle)
        XCTAssertEqual(store.createState, .idle)
        XCTAssertEqual(store.updateState, .idle)
        XCTAssertEqual(store.deleteState, .idle)
    }
}
