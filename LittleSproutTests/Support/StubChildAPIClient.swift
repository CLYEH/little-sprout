import Foundation
@testable import LittleSprout
import os

/// `ChildrenStore` 測試用假 `ChildAPIClient`——不打真網路，用可設定的 handler 決定各方法的
/// 表現（同 `StubFamilyAPIClient` 的模式，見該檔）。
final class StubChildAPIClient: ChildAPIClient, @unchecked Sendable {
    typealias ListChildrenHandler = @Sendable (UUID) async throws -> [Child]
    typealias CreateChildHandler = @Sendable (UUID, String, Date, String?) async throws -> UUID
    typealias UpdateChildHandler = @Sendable (UUID, String, Date, String?) async throws -> Void
    typealias SetChildDeletedHandler = @Sendable (UUID, Bool) async throws -> Void
    typealias FetchMyRoleHandler = @Sendable (UUID) async throws -> FamilyRole?

    enum StubError: Error {
        case unconfigured
    }

    struct UpdateChildCall: Equatable {
        let childID: UUID
        let name: String
        let birthday: Date
        let avatarURL: String?
    }

    struct SetChildDeletedCall: Equatable {
        let childID: UUID
        let deleted: Bool
    }

    private struct Box {
        var listChildrenHandler: ListChildrenHandler = { _ in [] }
        var createChildHandler: CreateChildHandler = { _, _, _, _ in throw StubError.unconfigured }
        var updateChildHandler: UpdateChildHandler = { _, _, _, _ in throw StubError.unconfigured }
        var updateChildCalls: [UpdateChildCall] = []
        var setChildDeletedHandler: SetChildDeletedHandler = { _, _ in throw StubError.unconfigured }
        var setChildDeletedCalls: [SetChildDeletedCall] = []
        var fetchMyRoleHandler: FetchMyRoleHandler = { _ in .owner }
        var listChildrenCallCount = 0
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var updateChildCalls: [UpdateChildCall] {
        box.withLock { $0.updateChildCalls }
    }

    var setChildDeletedCalls: [SetChildDeletedCall] {
        box.withLock { $0.setChildDeletedCalls }
    }

    var listChildrenCallCount: Int {
        box.withLock { $0.listChildrenCallCount }
    }

    func setListChildrenHandler(_ handler: @escaping ListChildrenHandler) {
        box.withLock { $0.listChildrenHandler = handler }
    }

    func setCreateChildHandler(_ handler: @escaping CreateChildHandler) {
        box.withLock { $0.createChildHandler = handler }
    }

    func setUpdateChildHandler(_ handler: @escaping UpdateChildHandler) {
        box.withLock { $0.updateChildHandler = handler }
    }

    func setSetChildDeletedHandler(_ handler: @escaping SetChildDeletedHandler) {
        box.withLock { $0.setChildDeletedHandler = handler }
    }

    func setFetchMyRoleHandler(_ handler: @escaping FetchMyRoleHandler) {
        box.withLock { $0.fetchMyRoleHandler = handler }
    }

    func listChildren(familyID: UUID) async throws -> [Child] {
        box.withLock { $0.listChildrenCallCount += 1 }
        let handler = box.withLock { $0.listChildrenHandler }
        return try await handler(familyID)
    }

    func createChild(familyID: UUID, name: String, birthday: Date, avatarURL: String?) async throws -> UUID {
        let handler = box.withLock { $0.createChildHandler }
        return try await handler(familyID, name, birthday, avatarURL)
    }

    func updateChild(childID: UUID, name: String, birthday: Date, avatarURL: String?) async throws {
        let call = UpdateChildCall(childID: childID, name: name, birthday: birthday, avatarURL: avatarURL)
        box.withLock { $0.updateChildCalls.append(call) }
        let handler = box.withLock { $0.updateChildHandler }
        try await handler(childID, name, birthday, avatarURL)
    }

    func setChildDeleted(childID: UUID, deleted: Bool) async throws {
        let call = SetChildDeletedCall(childID: childID, deleted: deleted)
        box.withLock { $0.setChildDeletedCalls.append(call) }
        let handler = box.withLock { $0.setChildDeletedHandler }
        try await handler(childID, deleted)
    }

    func fetchMyRole(familyID: UUID) async throws -> FamilyRole? {
        let handler = box.withLock { $0.fetchMyRoleHandler }
        return try await handler(familyID)
    }
}
