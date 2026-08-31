import Foundation
@testable import LittleSprout
import os

/// `FamilyStore` 測試用假 `FamilyAPIClient`——不打真網路，用可設定的 handler 決定
/// `createFamily`／`createInvite`／`fetchMyFamily`／加入審核流程六支方法（LS-108）怎麼表現
/// （同 `StubAuthService` 的模式，見該檔）。
final class StubFamilyAPIClient: FamilyAPIClient, @unchecked Sendable {
    typealias CreateFamilyHandler = @Sendable (String) async throws -> Family
    typealias FetchMyFamilyHandler = @Sendable () async throws -> Family?
    typealias CreateInviteHandler = @Sendable (UUID, FamilyRole, Date, Int) async throws -> InviteRecord
    typealias FetchLatestActiveInviteHandler = @Sendable (UUID) async throws -> InviteRecord?
    typealias RevokeInviteHandler = @Sendable (UUID) async throws -> Void
    typealias RequestJoinHandler = @Sendable (String) async throws -> JoinRequestOutcome
    typealias ApproveJoinHandler = @Sendable (UUID) async throws -> Void
    typealias RejectJoinHandler = @Sendable (UUID) async throws -> Void
    typealias WithdrawJoinHandler = @Sendable (UUID) async throws -> Void
    typealias ListJoinRequestsHandler = @Sendable () async throws -> [PendingJoinRequest]
    typealias MyJoinRequestHandler = @Sendable () async throws -> MyJoinRequest?

    enum StubError: Error {
        case unconfigured
    }

    /// SwiftLint `large_tuple`（>2 members）擋掉裸 tuple 記錄呼叫參數，改用具名 struct。
    struct CreateInviteCall: Equatable {
        let familyID: UUID
        let role: FamilyRole
        let expiresAt: Date
        let maxUses: Int
    }

    private struct Box {
        var createFamilyHandler: CreateFamilyHandler = { _ in throw StubError.unconfigured }
        var fetchMyFamilyHandler: FetchMyFamilyHandler = { nil }
        var createInviteHandler: CreateInviteHandler = { _, _, _, _ in throw StubError.unconfigured }
        var createInviteCalls: [CreateInviteCall] = []
        var fetchLatestActiveInviteHandler: FetchLatestActiveInviteHandler = { _ in nil }
        var revokeInviteHandler: RevokeInviteHandler = { _ in throw StubError.unconfigured }
        var revokeInviteCalls: [UUID] = []
        var requestJoinHandler: RequestJoinHandler = { _ in throw StubError.unconfigured }
        var requestJoinCalls: [String] = []
        var approveJoinHandler: ApproveJoinHandler = { _ in throw StubError.unconfigured }
        var approveJoinCalls: [UUID] = []
        var rejectJoinHandler: RejectJoinHandler = { _ in throw StubError.unconfigured }
        var rejectJoinCalls: [UUID] = []
        var withdrawJoinHandler: WithdrawJoinHandler = { _ in throw StubError.unconfigured }
        var withdrawJoinCalls: [UUID] = []
        var listJoinRequestsHandler: ListJoinRequestsHandler = { [] }
        var myJoinRequestHandler: MyJoinRequestHandler = { nil }
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var createInviteCalls: [CreateInviteCall] {
        box.withLock { $0.createInviteCalls }
    }

    var revokeInviteCalls: [UUID] {
        box.withLock { $0.revokeInviteCalls }
    }

    var requestJoinCalls: [String] {
        box.withLock { $0.requestJoinCalls }
    }

    var approveJoinCalls: [UUID] {
        box.withLock { $0.approveJoinCalls }
    }

    var rejectJoinCalls: [UUID] {
        box.withLock { $0.rejectJoinCalls }
    }

    var withdrawJoinCalls: [UUID] {
        box.withLock { $0.withdrawJoinCalls }
    }

    func setCreateFamilyHandler(_ handler: @escaping CreateFamilyHandler) {
        box.withLock { $0.createFamilyHandler = handler }
    }

    func setFetchMyFamilyHandler(_ handler: @escaping FetchMyFamilyHandler) {
        box.withLock { $0.fetchMyFamilyHandler = handler }
    }

    func setCreateInviteHandler(_ handler: @escaping CreateInviteHandler) {
        box.withLock { $0.createInviteHandler = handler }
    }

    func setFetchLatestActiveInviteHandler(_ handler: @escaping FetchLatestActiveInviteHandler) {
        box.withLock { $0.fetchLatestActiveInviteHandler = handler }
    }

    func setRevokeInviteHandler(_ handler: @escaping RevokeInviteHandler) {
        box.withLock { $0.revokeInviteHandler = handler }
    }

    func setRequestJoinHandler(_ handler: @escaping RequestJoinHandler) {
        box.withLock { $0.requestJoinHandler = handler }
    }

    func setApproveJoinHandler(_ handler: @escaping ApproveJoinHandler) {
        box.withLock { $0.approveJoinHandler = handler }
    }

    func setRejectJoinHandler(_ handler: @escaping RejectJoinHandler) {
        box.withLock { $0.rejectJoinHandler = handler }
    }

    func setWithdrawJoinHandler(_ handler: @escaping WithdrawJoinHandler) {
        box.withLock { $0.withdrawJoinHandler = handler }
    }

    func setListJoinRequestsHandler(_ handler: @escaping ListJoinRequestsHandler) {
        box.withLock { $0.listJoinRequestsHandler = handler }
    }

    func setMyJoinRequestHandler(_ handler: @escaping MyJoinRequestHandler) {
        box.withLock { $0.myJoinRequestHandler = handler }
    }

    func createFamily(name: String) async throws -> Family {
        let handler = box.withLock { $0.createFamilyHandler }
        return try await handler(name)
    }

    func fetchMyFamily() async throws -> Family? {
        let handler = box.withLock { $0.fetchMyFamilyHandler }
        return try await handler()
    }

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> InviteRecord {
        let call = CreateInviteCall(familyID: familyID, role: role, expiresAt: expiresAt, maxUses: maxUses)
        box.withLock { $0.createInviteCalls.append(call) }
        let handler = box.withLock { $0.createInviteHandler }
        return try await handler(familyID, role, expiresAt, maxUses)
    }

    func fetchLatestActiveInvite(familyID: UUID) async throws -> InviteRecord? {
        let handler = box.withLock { $0.fetchLatestActiveInviteHandler }
        return try await handler(familyID)
    }

    func revokeInvite(id: UUID) async throws {
        box.withLock { $0.revokeInviteCalls.append(id) }
        let handler = box.withLock { $0.revokeInviteHandler }
        try await handler(id)
    }

    func updateFamilyName(familyID: UUID, name: String) async throws { throw StubError.unconfigured }

    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws { throw StubError.unconfigured }

    func requestJoin(code: String) async throws -> JoinRequestOutcome {
        box.withLock { $0.requestJoinCalls.append(code) }
        let handler = box.withLock { $0.requestJoinHandler }
        return try await handler(code)
    }

    func approveJoin(requestID: UUID) async throws {
        box.withLock { $0.approveJoinCalls.append(requestID) }
        let handler = box.withLock { $0.approveJoinHandler }
        try await handler(requestID)
    }

    func rejectJoin(requestID: UUID) async throws {
        box.withLock { $0.rejectJoinCalls.append(requestID) }
        let handler = box.withLock { $0.rejectJoinHandler }
        try await handler(requestID)
    }

    func withdrawJoin(requestID: UUID) async throws {
        box.withLock { $0.withdrawJoinCalls.append(requestID) }
        let handler = box.withLock { $0.withdrawJoinHandler }
        try await handler(requestID)
    }

    func listJoinRequests() async throws -> [PendingJoinRequest] {
        let handler = box.withLock { $0.listJoinRequestsHandler }
        return try await handler()
    }

    func myJoinRequest() async throws -> MyJoinRequest? {
        let handler = box.withLock { $0.myJoinRequestHandler }
        return try await handler()
    }
}
