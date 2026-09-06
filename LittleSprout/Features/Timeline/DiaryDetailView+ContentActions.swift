import SwiftUI

/// LS-189：`DiaryDetailView` 導覽列「⋯」內容操作表整條流程——抽到獨立檔案（同
/// `SettingsView+Sheets.swift`／`FamilyMembersView+Sheets.swift` 既有先例，`DiaryDetailView.swift`
/// 本體已經有瀑布流照片牆／影片播放兩段邏輯，疊上這條流程會超過 SwiftLint `file_length`）。
///
/// 流程：「⋯」→ 非同步查作者（`SafetyAPIClient.fetchContentAuthor`）→ `ContentActionsSheet`
/// （05）→ 依選的動作分流：
///   - 檢舉 → `ReportReasonSheet`（05b）→ `ReportSentSheet`（05c）
///   - 封鎖 → `BlockConfirmSheet`（05d）
///   - Owner 移除 → `OwnerRemoveContentConfirmSheet`（05e）→ 成功後本地移除＋回上一頁
///   - 刪除（自己的內容）→ 既有 `DiaryDeleteConfirmationSheet`（LS-190）→ 成功後本地移除＋回上
///     一頁
///
/// 每一步都遵守 `DeleteConfirmationSheet` 定下的既有規約（LS-190 R2 m3）：sheet 自己先
/// `dismiss()`，才呼叫成功回呼——這裡各 `on...` 閉包因此都能安全地把下一個 `@State` 設成非
/// nil，不會撞到「舊 sheet 還沒關就疊一張新的」的時序問題。
extension DiaryDetailView {
    var contentActionsButton: some View {
        Button(action: openContentActions) {
            Group {
                if isResolvingContentActions {
                    ProgressView()
                } else {
                    Image(systemName: "ellipsis.circle").appIconFrame(.medium)
                }
            }
            // 一開始用 `.toolbar { ToolbarItem(placement: .topBarTrailing) { ... } }`＋padding
            // 撐大內容——模擬器實測熱區只有 57×36pt，跟 `DiaryEditorView` 文件註解描述的
            // 「padding 直接加高內容本身」現象不同：nav bar bar button item 的高度似乎被系統
            // 夾在導覽列本身的高度內，padding 對高度不生效（對寬度有效，57pt 已經比純 icon 寬）。
            // 改成一般內容區塊裡的按鈕（同 `FamilyMembersView.actionMenu` 既有手法）——明確
            // `.frame(width:height:)` 而不是 padding，`tap-target-check.sh` 實測穩定 ≥44×44pt。
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .disabled(diaryContent == nil || isResolvingContentActions)
        .accessibilityLabel("更多操作")
    }

    /// 不可見的 `EmptyView`，掛整條流程的 `.sheet` 鏈——`.sheet` 掛在樹上哪個節點不影響呈現
    /// （見 `DiaryDetailView.body` 的 `.overlay` 呼叫端註解）。
    var contentActionsSheetHost: some View {
        EmptyView()
            .sheet(item: $contentActionsContext) { context in
                ContentActionsSheet(headline: context.target.headline, actions: context.actions) { action in
                    handleContentAction(action, context: context)
                }
            }
            .sheet(item: $reportFlowTarget) { target in
                ReportReasonSheet(
                    familyName: familyStore.myFamily?.name ?? "", familyID: target.familyID,
                    targetType: target.type, targetID: target.id, safetyAPIClient: safetyAPIClient,
                    onSent: { showsReportSent = true }
                )
            }
            .sheet(isPresented: $showsReportSent) {
                ReportSentSheet(familyName: familyStore.myFamily?.name ?? "")
            }
            .sheet(item: $blockConfirmContext) { context in
                BlockConfirmSheet(
                    familyID: context.familyID, familyName: familyStore.myFamily?.name ?? "",
                    blockedID: context.memberID, memberName: context.memberName, safetyAPIClient: safetyAPIClient
                )
            }
            .sheet(item: $removeConfirmTarget) { target in
                OwnerRemoveContentConfirmSheet(
                    familyName: familyStore.myFamily?.name ?? "", targetType: target.type, targetID: target.id,
                    safetyAPIClient: safetyAPIClient, onRemoved: contentRemoved
                )
            }
            .sheet(isPresented: $showsDeleteConfirmation) {
                DiaryDeleteConfirmationSheet(
                    diaryID: diaryID, diaryBody: diaryContent?.body ?? "", diaryAPIClient: diaryAPIClient,
                    onDeleted: contentRemoved
                )
            }
    }

    /// 「⋯」按下——非同步查作者身分後才組出動作列並開 05。查詢期間按鈕顯示轉圈、再次點擊
    /// 被 `disabled` 擋住（同 `DeleteConfirmationSheet.confirmTapped` 的 `guard !isSubmitting`
    /// 既有慣例，這裡用 `disabled` modifier 表達同一件事）。
    func openContentActions() {
        guard !isResolvingContentActions, let diaryContent, let familyID = familyStore.myFamily?.id,
              let viewerUserID = familyStore.ownerUserID, let viewerRole = childrenStore.myRole else { return }
        isResolvingContentActions = true
        Task {
            defer { isResolvingContentActions = false }
            let authorID = try? await safetyAPIClient.fetchContentAuthor(targetType: .diary, targetID: diaryID)
            let authorDisplayName = authorID
                .flatMap { id in familyStore.members.first { $0.userID == id }?.displayName } ?? "這位成員"
            let target = ContentActionTarget(
                type: .diary, id: diaryID, familyID: familyID,
                headline: "「\(DiaryDeleteConfirmationCopy.excerpt(from: diaryContent.body))」"
            )
            let actions = contentActions(
                for: target, viewerRole: viewerRole, viewerUserID: viewerUserID,
                authorID: authorID, authorDisplayName: authorDisplayName
            )
            contentActionsContext = DiaryContentActionsContext(target: target, actions: actions)
        }
    }

    private func handleContentAction(_ action: ContentAction, context: DiaryContentActionsContext) {
        switch action {
        case .report:
            reportFlowTarget = context.target
        case .block(let memberID, let memberName):
            blockConfirmContext = DiaryBlockConfirmContext(
                familyID: context.target.familyID, memberID: memberID, memberName: memberName
            )
        case .removeAsOwner:
            removeConfirmTarget = context.target
        case .deleteOwn:
            showsDeleteConfirmation = true
        }
    }

    /// Owner 移除／自己刪除成功後共用的收尾：這篇日記已經不在了，本地立即移除（不等下一次
    /// `refresh()`）＋回上一頁（同 `DiaryDeleteConfirmationSheet` 文件註解的既有分工——這裡就是
    /// 那個「呼叫端負責本地移除與導覽收尾」）。
    private func contentRemoved() {
        timelineStore.removeDiaryEntryLocally(diaryID: diaryID)
        dismiss()
    }
}

/// `ContentActionsSheet`（05）呈現用的 item——把算好的動作列跟目標綁在一起，`.sheet(item:)`
/// 需要 `Identifiable`。
struct DiaryContentActionsContext: Identifiable {
    let target: ContentActionTarget
    let actions: [ContentAction]
    var id: UUID { target.id }
}

/// `BlockConfirmSheet`（05d）呈現用的 item。
struct DiaryBlockConfirmContext: Identifiable {
    let familyID: UUID
    let memberID: UUID
    let memberName: String
    var id: UUID { memberID }
}
