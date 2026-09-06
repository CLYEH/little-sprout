import Foundation
@testable import LittleSprout
import os

/// 內容操作表（LS-189）測試用假 `SafetyAPIClient`——不打真網路（同 `StubDiaryAPIClient` 的模式，
/// 見該檔）。
final class StubSafetyAPIClient: SafetyAPIClient, @unchecked Sendable {
    typealias ReportHandler = @Sendable (UUID, ContentTargetType, UUID, ReportReason) async throws -> Void
    typealias BlockHandler = @Sendable (UUID, UUID) async throws -> Void
    typealias RemoveHandler = @Sendable (ContentTargetType, UUID) async throws -> Void
    typealias ResolveHandler = @Sendable (UUID) async throws -> Void

    struct ReportCall: Equatable {
        let familyID: UUID
        let targetType: ContentTargetType
        let targetID: UUID
        let reason: ReportReason
    }

    struct BlockCall: Equatable {
        let familyID: UUID
        let blockedID: UUID
    }

    struct RemoveCall: Equatable {
        let targetType: ContentTargetType
        let targetID: UUID
    }

    private struct Box {
        var authorID: UUID?
        var blockedUsers: [BlockedUserRecord] = []
        var pendingReports: [ContentReportRecord] = []
        var reportSnippet: String?
        var reportHandler: ReportHandler = { _, _, _, _ in }
        var blockHandler: BlockHandler = { _, _ in }
        var unblockHandler: BlockHandler = { _, _ in }
        var removeHandler: RemoveHandler = { _, _ in }
        var resolveHandler: ResolveHandler = { _ in }
        var reportCalls: [ReportCall] = []
        var blockCalls: [BlockCall] = []
        var unblockCalls: [BlockCall] = []
        var removeCalls: [RemoveCall] = []
        var resolveCalls: [UUID] = []
    }

    private let box: OSAllocatedUnfairLock<Box>

    init(
        authorID: UUID? = nil, blockedUsers: [BlockedUserRecord] = [],
        pendingReports: [ContentReportRecord] = [], reportSnippet: String? = nil
    ) {
        box = OSAllocatedUnfairLock(initialState: Box(
            authorID: authorID, blockedUsers: blockedUsers, pendingReports: pendingReports,
            reportSnippet: reportSnippet
        ))
    }

    var reportCalls: [ReportCall] { box.withLock { $0.reportCalls } }
    var blockCalls: [BlockCall] { box.withLock { $0.blockCalls } }
    var unblockCalls: [BlockCall] { box.withLock { $0.unblockCalls } }
    var removeCalls: [RemoveCall] { box.withLock { $0.removeCalls } }
    var resolveCalls: [UUID] { box.withLock { $0.resolveCalls } }

    func setReportHandler(_ handler: @escaping ReportHandler) {
        box.withLock { $0.reportHandler = handler }
    }

    func setRemoveHandler(_ handler: @escaping RemoveHandler) {
        box.withLock { $0.removeHandler = handler }
    }

    func setResolveHandler(_ handler: @escaping ResolveHandler) {
        box.withLock { $0.resolveHandler = handler }
    }

    func fetchContentAuthor(targetType: ContentTargetType, targetID: UUID) async throws -> UUID? {
        box.withLock { $0.authorID }
    }

    func reportContent(
        familyID: UUID, targetType: ContentTargetType, targetID: UUID, reason: ReportReason
    ) async throws {
        let call = ReportCall(familyID: familyID, targetType: targetType, targetID: targetID, reason: reason)
        box.withLock { $0.reportCalls.append(call) }
        let handler = box.withLock { $0.reportHandler }
        try await handler(familyID, targetType, targetID, reason)
    }

    func blockUser(familyID: UUID, blockedID: UUID) async throws {
        let call = BlockCall(familyID: familyID, blockedID: blockedID)
        box.withLock { $0.blockCalls.append(call) }
        let handler = box.withLock { $0.blockHandler }
        try await handler(familyID, blockedID)
    }

    func unblockUser(familyID: UUID, blockedID: UUID) async throws {
        let call = BlockCall(familyID: familyID, blockedID: blockedID)
        box.withLock {
            $0.unblockCalls.append(call)
            $0.blockedUsers.removeAll { $0.blockedID == blockedID }
        }
        let handler = box.withLock { $0.unblockHandler }
        try await handler(familyID, blockedID)
    }

    func removeContentAsOwner(targetType: ContentTargetType, targetID: UUID) async throws {
        let call = RemoveCall(targetType: targetType, targetID: targetID)
        box.withLock { $0.removeCalls.append(call) }
        let handler = box.withLock { $0.removeHandler }
        try await handler(targetType, targetID)
    }

    func listBlockedUsers(familyID: UUID) async throws -> [BlockedUserRecord] {
        box.withLock { $0.blockedUsers }
    }

    func listPendingReports(familyID: UUID) async throws -> [ContentReportRecord] {
        box.withLock { $0.pendingReports }
    }

    func markReportResolved(reportID: UUID) async throws {
        box.withLock { $0.resolveCalls.append(reportID) }
        let handler = box.withLock { $0.resolveHandler }
        try await handler(reportID)
    }

    func fetchReportSnippet(targetType: ContentTargetType, targetID: UUID) async throws -> String? {
        box.withLock { $0.reportSnippet }
    }
}
