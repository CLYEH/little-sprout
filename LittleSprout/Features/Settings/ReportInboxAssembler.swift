import Foundation

/// LS-189 R2（merge-review R1 m1）：`ReportInboxView.load()` 原本在 `assembleItems` 裡逐筆序列
/// `await fetchReportSnippet`——N 筆待處理檢舉＝N 次序列往返，載入期間畫面純轉圈。抽成獨立、
/// 脫離 View 可直接單元測試的純函式（同 `ContentActions.swift` 把邏輯抽出 View 的既有理由）：
/// 依 `targetType` 分組後每種型別只打一次批次查詢（`SafetyAPIClient.fetchReportSnippets`），
/// 4 種型別最多 3 次往返（`media` 不查網路），不再隨檢舉筆數線性成長。
///
/// **顯示名稱不在這裡解析**（LS-189 R2 m4）：`ReportCardItem` 不含 `reporterName`——那個交給
/// `ReportInboxView.reporterName(for:)` 在 render 當下查 `familyStore.members`（同
/// `BlockListView.displayName(for:)` 既有寫法）。這裡凍結的只有內容預覽文字，不是因為預覽不會
/// 過期（理論上也會，但內容預覽本來就不像成員名字那樣會在同一次 session 內合理地變動），而是
/// 沒有更簡單的辦法在不重查的情況下保持它是最新的——跟 m4 純粹是「一開始就不該凍結」不同性質。
enum ReportInboxAssembler {
    static func assembleItems(
        _ reports: [ContentReportRecord], safetyAPIClient: SafetyAPIClient
    ) async -> [ReportCardItem] {
        var snippetsByType: [ContentTargetType: [UUID: String]] = [:]
        // `media` 沒有文字內容欄位——連批次查詢都不觸發（`SafetyAPIClient.fetchReportSnippets`
        // 對 `.media` 一律回空字典、不打網路，但這裡連那個函式呼叫本身都省下，同原本
        // `fetchReportSnippet`（單筆版）文件註解「不需要額外一支查詢」的既有理由）。
        for targetType in ContentTargetType.allCases where targetType != .media {
            let ids = reports.filter { $0.targetType == targetType }.map(\.targetID)
            guard !ids.isEmpty else { continue }
            snippetsByType[targetType] = (try? await safetyAPIClient.fetchReportSnippets(
                targetType: targetType, targetIDs: ids
            )) ?? [:]
        }
        return reports.map { report in
            let snippet = snippetsByType[report.targetType]?[report.targetID]
                ?? (report.targetType == .media ? "一張照片或影片" : "這則內容已經被移除")
            return ReportCardItem(report: report, snippet: snippet)
        }
    }
}
