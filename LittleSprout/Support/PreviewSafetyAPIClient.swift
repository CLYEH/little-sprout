#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview`／`TapTargetGateHarness` 用的假 `SafetyAPIClient`——不打真網路、不需要
/// `Config/Secrets.xcconfig`（同 `PreviewCommentAPIClient`／`PreviewDiaryAPIClient` 的角色）。
/// 生產路徑一律用 `SupabaseSafetyAPIClient`。
final class PreviewSafetyAPIClient: SafetyAPIClient, @unchecked Sendable {
    var authorID: UUID?
    var blockedUsers: [BlockedUserRecord] = []
    var pendingReports: [ContentReportRecord] = []
    var reportSnippet: String?

    init(
        authorID: UUID? = nil, blockedUsers: [BlockedUserRecord] = [],
        pendingReports: [ContentReportRecord] = [], reportSnippet: String? = nil
    ) {
        self.authorID = authorID
        self.blockedUsers = blockedUsers
        self.pendingReports = pendingReports
        self.reportSnippet = reportSnippet
    }

    func fetchContentAuthor(targetType: ContentTargetType, targetID: UUID) async throws -> UUID? { authorID }

    func reportContent(
        familyID: UUID, targetType: ContentTargetType, targetID: UUID, reason: ReportReason
    ) async throws {}

    func blockUser(familyID: UUID, blockedID: UUID) async throws {}

    func unblockUser(familyID: UUID, blockedID: UUID) async throws {
        blockedUsers.removeAll { $0.blockedID == blockedID }
    }

    func removeContentAsOwner(targetType: ContentTargetType, targetID: UUID) async throws {}

    func listBlockedUsers(familyID: UUID) async throws -> [BlockedUserRecord] { blockedUsers }

    func listPendingReports(familyID: UUID) async throws -> [ContentReportRecord] { pendingReports }

    func markReportResolved(reportID: UUID) async throws {
        pendingReports.removeAll { $0.id == reportID }
    }

    func fetchReportSnippet(targetType: ContentTargetType, targetID: UUID) async throws -> String? { reportSnippet }
}
#endif
