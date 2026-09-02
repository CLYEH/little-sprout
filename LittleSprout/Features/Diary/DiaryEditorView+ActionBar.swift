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

    private func errorRow(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill").appIconFrame(.small).foregroundStyle(Color.lsDanger)
            Text(error.userFacingMessage).appFont(.note, weight: .semibold).foregroundStyle(Color.lsDanger)
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

    private var publishButton: some View {
        PrimaryButton(
            icon: isRetrying ? "arrow.clockwise" : "paperplane.fill",
            title: isRetrying ? "重新發佈" : "發佈日記",
            isLoading: store.publishState.isInFlight,
            loadingTitle: "發佈中…",
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
