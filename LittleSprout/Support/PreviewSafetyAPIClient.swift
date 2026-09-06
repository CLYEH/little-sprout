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
    /// LS-189 R2（merge-review R1 B1）：讓 harness／UITest 能模擬「這則沒問題」失敗，驗證
    /// `ReportInboxView.markNoIssue` 的錯誤狀態正確顯示（見該檔文件註解）——非 nil 時
    /// `markReportResolved` 一律 throw 這個錯誤，不真的把報告從 `pendingReports` 移除。
    var markResolvedError: AppError?
    /// LS-189 R2（merge-review R1 B4）：讓 harness／UITest 能模擬 `report_content` 的 LS026
    /// （target 存在但屬於別的家庭），驗證 `ReportReasonSheet` 的「這則內容已經不存在了」
    /// 專屬文案＋單一「關閉」正確顯示（見該檔 `isTargetGone` 文件註解）。
    var reportContentError: AppError?

    init(
        authorID: UUID? = nil, blockedUsers: [BlockedUserRecord] = [],
        pendingReports: [ContentReportRecord] = [], reportSnippet: String? = nil,
        markResolvedError: AppError? = nil, reportContentError: AppError? = nil
    ) {
        self.authorID = authorID
        self.blockedUsers = blockedUsers
        self.pendingReports = pendingReports
        self.reportSnippet = reportSnippet
        self.markResolvedError = markResolvedError
        self.reportContentError = reportContentError
    }

    func fetchContentAuthor(targetType: ContentTargetType, targetID: UUID) async throws -> UUID? { authorID }

    func reportContent(
        familyID: UUID, targetType: ContentTargetType, targetID: UUID, reason: ReportReason
    ) async throws {
        if let reportContentError { throw reportContentError }
    }

    func blockUser(familyID: UUID, blockedID: UUID) async throws {}

    func unblockUser(familyID: UUID, blockedID: UUID) async throws {
        blockedUsers.removeAll { $0.blockedID == blockedID }
    }

    func removeContentAsOwner(targetType: ContentTargetType, targetID: UUID) async throws {}

    func listBlockedUsers(familyID: UUID) async throws -> [BlockedUserRecord] { blockedUsers }

    func listPendingReports(familyID: UUID) async throws -> [ContentReportRecord] { pendingReports }

    func markReportResolved(reportID: UUID) async throws {
        if let markResolvedError { throw markResolvedError }
        pendingReports.removeAll { $0.id == reportID }
    }

    func fetchReportSnippets(targetType: ContentTargetType, targetIDs: [UUID]) async throws -> [UUID: String] {
        guard let reportSnippet else { return [:] }
        return Dictionary(uniqueKeysWithValues: targetIDs.map { ($0, reportSnippet) })
    }
}
#endif
