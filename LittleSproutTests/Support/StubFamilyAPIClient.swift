import Foundation
@testable import LittleSprout
import os

/// `FamilyStore` 測試用假 `FamilyAPIClient`——不打真網路，用可設定的 handler 決定
/// `createFamily`／`createInvite`／`fetchMyFamily` 三個 `FamilyStore` 實際會呼叫的方法怎麼
/// 表現（同 `StubAuthService` 的模式，見該檔）。其餘協定方法（加入審核流程）本測試套件用不到，
/// 呼叫到就丟 `unconfigured`。
final class StubFamilyAPIClient: FamilyAPIClient, @unchecked Sendable {
    typealias CreateFamilyHandler = @Sendable (String) async throws -> Family
    typealias FetchMyFamilyHandler = @Sendable () async throws -> Family?
    typealias CreateInviteHandler = @Sendable (UUID, FamilyRole, Date, Int) async throws -> String

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
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var createInviteCalls: [CreateInviteCall] {
        box.withLock { $0.createInviteCalls }
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

    func createFamily(name: String) async throws -> Family {
        let handler = box.withLock { $0.createFamilyHandler }
        return try await handler(name)
    }

    func fetchMyFamily() async throws -> Family? {
        let handler = box.withLock { $0.fetchMyFamilyHandler }
        return try await handler()
    }

    func createInvite(familyID: UUID, role: FamilyRole, expiresAt: Date, maxUses: Int) async throws -> String {
        let call = CreateInviteCall(familyID: familyID, role: role, expiresAt: expiresAt, maxUses: maxUses)
        box.withLock { $0.createInviteCalls.append(call) }
        let handler = box.withLock { $0.createInviteHandler }
        return try await handler(familyID, role, expiresAt, maxUses)
    }

    func updateFamilyName(familyID: UUID, name: String) async throws { throw StubError.unconfigured }

    func setRequireApproval(familyID: UUID, requireApproval: Bool) async throws { throw StubError.unconfigured }

    func requestJoin(code: String) async throws -> JoinRequestOutcome { throw StubError.unconfigured }

    func approveJoin(requestID: UUID) async throws { throw StubError.unconfigured }

    func rejectJoin(requestID: UUID) async throws { throw StubError.unconfigured }

    func withdrawJoin(requestID: UUID) async throws { throw StubError.unconfigured }

    func listJoinRequests() async throws -> [PendingJoinRequest] { throw StubError.unconfigured }

    func myJoinRequest() async throws -> MyJoinRequest? { throw StubError.unconfigured }
}
