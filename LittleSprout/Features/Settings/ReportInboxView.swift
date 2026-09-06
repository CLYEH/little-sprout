import SwiftUI

/// 檢舉收件匣（LS-189，依 LS-152 稿 `J5sQHy`／AX3 `yResD`／空狀態 `IpLKZ`，Owner 限定）——
/// 待處理檢舉列表，每張卡「查看內容」／「這則沒問題」／「移除內容」三個動作。取代 LS-188 的
/// 最小佔位（見該檔沿革）。
///
/// 「查看內容」（`docs/API.md` 沒有提供跨四種內容型別的統一導覽方式）本票以「顯示完整內容
/// 文字」的輕量 sheet 實作，不深入導覽到日記詳情／相簿詳情等各自畫面——`AlbumDetailView`
/// （LS-166）仍是佔位、留言 UI 本體（LS-22）也還沒落地，深度導覽留給那兩張票接手時再擴充，
/// 這裡先讓 Owner 能讀到完整內容以判斷是否要移除。
struct ReportInboxView: View {
    let familyStore: FamilyStore
    let safetyAPIClient: SafetyAPIClient

    @State private var loadState: TimelineOperationState = .idle
    @State private var items: [ReportCardItem] = []
    @State private var viewedItem: ReportCardItem?
    @State private var removeTarget: ContentActionTarget?
    @State private var resolvingReportID: UUID?
    @State private var actionError: AppError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                header
                content
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
            .padding(.bottom, AppSpacing.block)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task(id: familyStore.myFamily?.id) {
            await load()
        }
        .sheet(item: $viewedItem) { item in
            ReportContentPreviewSheet(item: item)
        }
        .sheet(item: $removeTarget) { target in
            OwnerRemoveContentConfirmSheet(
                familyName: familyStore.myFamily?.name ?? "", targetType: target.type, targetID: target.id,
                safetyAPIClient: safetyAPIClient,
                onRemoved: { items.removeAll { $0.report.targetID == target.id } }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("檢舉")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(subtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var subtitle: String {
        let familyName = familyStore.myFamily?.name ?? ""
        guard !items.isEmpty else { return "「\(familyName)」目前沒有待處理的檢舉。" }
        return "「\(familyName)」目前有 \(items.count) 則待處理的檢舉。"
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .submitting:
            if items.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                reportList
            }
        case .failure(let error):
            errorRow(error)
        case .success:
            if items.isEmpty {
                emptyState
            } else {
                reportList
            }
        }
    }

    private var reportList: some View {
        VStack(spacing: AppSpacing.item) {
            ForEach(items) { item in reportCard(item) }
        }
    }

    private func reportCard(_ item: ReportCardItem) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            HStack(spacing: AppSpacing.tight) {
                Image(systemName: item.report.targetType.icon).appIconFrame(.small)
                Text(item.report.targetType.displayLabel).appFont(.note, weight: .semibold)
            }
            .foregroundStyle(Color.lsTextSecondary)
            Text(item.snippet)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
                .lineLimit(2)
            Pill(icon: "flag.fill", text: item.reasonDisplayLabel)
            Text("由 \(item.reporterName) 檢舉・\(JoinRequestTimeFormatter.format(item.report.createdAt))")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
            if let actionError, resolvingReportID == item.id {
                Text(actionError.userFacingMessage).appFont(.note).foregroundStyle(Color.lsDanger)
            }
            viewButton(item)
            HStack(spacing: AppSpacing.block) {
                noIssueButton(item)
                removeButton(item)
            }
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusMedium).strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    private func viewButton(_ item: ReportCardItem) -> some View {
        Button {
            viewedItem = item
        } label: {
            Text("查看內容")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsOnAccent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
    }

    private func noIssueButton(_ item: ReportCardItem) -> some View {
        Button {
            markNoIssue(item)
        } label: {
            Text("這則沒問題")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
                .underline()
                .frame(minHeight: 44)
        }
        .disabled(resolvingReportID == item.id)
    }

    private func removeButton(_ item: ReportCardItem) -> some View {
        Button {
            removeTarget = ContentActionTarget(
                type: item.report.targetType, id: item.report.targetID,
                familyID: familyStore.myFamily?.id ?? UUID(), headline: item.snippet
            )
        } label: {
            Text("移除內容")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
                .frame(minHeight: 44)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.label) {
            Image(systemName: "checkmark.shield.fill").appIconFrame(.large).foregroundStyle(Color.lsTextSecondary)
            Text("目前沒有需要處理的檢舉。有人送出檢舉時，會出現在這裡。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.section)
    }

    private func errorRow(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(error.userFacingMessage)
                .appFont(.note)
                .foregroundStyle(Color.lsDanger)
            Button("重試") { Task { await load() } }
                .appFont(.body, weight: .semibold)
        }
    }

    /// 「這則沒問題」——直接把檢舉標成已處理（`docs/API.md` §3：owner-only、只能改成
    /// `resolved`），不移除內容本身。
    private func markNoIssue(_ item: ReportCardItem) {
        resolvingReportID = item.id
        actionError = nil
        Task {
            defer { resolvingReportID = nil }
            do {
                try await safetyAPIClient.markReportResolved(reportID: item.report.id)
                items.removeAll { $0.id == item.id }
            } catch {
                actionError = AppError.map(error)
            }
        }
    }

    private func load() async {
        guard let familyID = familyStore.myFamily?.id else { return }
        loadState = .submitting
        do {
            let reports = try await safetyAPIClient.listPendingReports(familyID: familyID)
            items = try await assembleItems(reports)
            loadState = .success
        } catch {
            loadState = .failure(AppError.map(error))
        }
    }

    /// 逐筆解析檢舉人顯示名稱（`familyStore.members` 本地查表）與內容預覽（`fetchReportSnippet`
    /// ——`media` 沒有文字內容，回傳 nil 時顯示通用標籤；其餘型別若查不到（內容已被硬刪，理論
    /// 上不會發生，軟刪列仍在）顯示「這則內容已經被移除」）。
    private func assembleItems(_ reports: [ContentReportRecord]) async throws -> [ReportCardItem] {
        var result: [ReportCardItem] = []
        for report in reports {
            let reporterName = report.reporterID
                .flatMap { id in familyStore.members.first { $0.userID == id }?.displayName } ?? "一位家人"
            let fetchedSnippet = try? await safetyAPIClient.fetchReportSnippet(
                targetType: report.targetType, targetID: report.targetID
            )
            let snippet = fetchedSnippet ?? (report.targetType == .media ? "一張照片或影片" : "這則內容已經被移除")
            result.append(ReportCardItem(report: report, reporterName: reporterName, snippet: snippet))
        }
        return result
    }
}

/// 07 檢舉卡片組好的顯示資料——把 `ContentReportRecord` 加上解析出來的檢舉人名稱與內容預覽。
struct ReportCardItem: Identifiable, Equatable {
    let report: ContentReportRecord
    let reporterName: String
    let snippet: String

    var id: UUID { report.id }

    /// `report.reason` 是 `ReportReason` 的 ASCII key（`report_content` 契約，見
    /// `SafetyModels.swift`）；解析失敗（舊資料或非本 app 送出的自由文字）顯示原始字串兜底。
    var reasonDisplayLabel: String {
        ReportReason(rawValue: report.reason)?.displayLabel ?? report.reason
    }
}

/// 「查看內容」——見 `ReportInboxView` 文件註解，純顯示完整內容文字，不深入導覽。
private struct ReportContentPreviewSheet: View {
    let item: ReportCardItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(item.snippet)
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.screenPad)
            }
            .navigationTitle(item.report.targetType.displayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ReportInboxView(familyStore: .preview(), safetyAPIClient: PreviewSafetyAPIClient())
    }
}
#endif
