import SwiftUI

/// 釘底 Action Bar（`design/littlesprout.pen` `LS-21 / 12` Action Bar；`InviteFamilyView` 既有的
/// 「hairline＋依狀態變化的主要動作」慣例，見 `InviteFamilyView+ActionBar.swift`）。12c 發佈
/// 失敗時在按鈕上方插入 Error Row＋安心句，按鈕本身文案／icon 換成「重新發佈」；草稿內容完全
/// 不清空（見 `DiaryComposerStore.publish()` 文件註解）。
extension DiaryEditorView {
    var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            actionBarContent
                .padding(.vertical, AppSpacing.item)
                .padding(.horizontal, horizontalPadding)
        }
        .background(Color.lsSurface)
    }

    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? AppSpacing.screenPadLarge : AppSpacing.screenPad
    }

    private var actionBarContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            if case .failure(let error) = store.publishState {
                errorRow(error)
                Text("你寫的內容還在，可以直接重試。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            publishButtonRow
        }
    }

    /// 顯示文案的分流邏輯在 `DiaryPublishErrorMessage.displayText(for:)`（`DiaryComposerModels.swift`）
    /// ——抽成跟 SwiftUI 脫鉤的純函式，才能被單元測試直接釘住「螢幕上出現的字」（merge-review
    /// R1 M1／I4）。
    private func errorRow(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small).foregroundStyle(Color.lsDanger)
            Text(DiaryPublishErrorMessage.displayText(for: error))
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
        }
    }

    /// iPad：按鈕不撐滿寬度、靠右對齊（`b3PELj`）；iPhone：滿版寬（`mkxzU`）。
    @ViewBuilder
    private var publishButtonRow: some View {
        if horizontalSizeClass == .regular {
            HStack {
                Spacer(minLength: 0)
                publishButton.frame(width: 280)
            }
        } else {
            publishButton
        }
    }

    private var isRetrying: Bool {
        if case .failure = store.publishState { return true }
        return false
    }

    /// merge-review R1 M3：照片還在背景解碼（`loadPicked`）時按發佈，`uploadAllMedia()` 只會
    /// 拿到當下已經 append 完成的快照，之後才 append 進來的照片會被靜默漏掉——`isLoading`
    /// 併入 `store.isLoadingPickedItems`，讓 `PrimaryButton` 自己的 `.disabled(isLoading)`
    /// 擋下這顆按鈕（不是額外疊一層 `.disabled(...)`：那樣會被 `PrimaryButton` 內部自己的
    /// `.disabled(isLoading)`——更靠近 Button 本體、環境值以它為準——蓋掉外層的停用，見
    /// commit 說明）。文案分開講：真的在傳的時候講「發佈中…」，只是在等照片解碼完成時講
    /// 「照片載入中…」，不要讓使用者誤以為已經按到發佈。
    private var publishButton: some View {
        PrimaryButton(
            icon: isRetrying ? "arrow.clockwise" : "paperplane.fill",
            title: isRetrying ? "重新發佈" : "發佈日記",
            isLoading: store.publishState.isInFlight || store.isLoadingPickedItems,
            loadingTitle: store.isLoadingPickedItems ? "照片載入中…" : "發佈中…",
            action: submit
        )
    }

    func submit() {
        guard !store.publishState.isInFlight else { return }
        Task {
            if await store.publish() {
                dismiss()
            }
        }
    }
}
