import SwiftUI

/// LS-218：輸入列——單行成長 `TextField`＋送出鈕（畫面唯一 `$accent`；44／AX3 56；空白時
/// disabled，票文範圍 3）。拆到獨立檔案的理由見 `CommentsSheetView.swift` 檔頭註解。
extension CommentsSheetView {
    var footer: some View {
        HStack(spacing: AppSpacing.group) {
            ProfilePrintChip(size: avatarSize)
            TextField("留言...", text: $draft, axis: .vertical)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
                .padding(.vertical, AppSpacing.controlPaddingTap)
                .padding(.horizontal, AppSpacing.insetCard)
                .background(Color.lsBackground, in: Capsule())
                .accessibilityIdentifier(QAAccessibilityID.commentInputField)
            sendButton
        }
        .padding(.vertical, AppSpacing.item)
        .padding(.bottom, AppSpacing.block)
    }

    private var sendButtonSize: CGFloat { isAX3 ? 56 : 44 }
    private var sendIconSize: CGFloat { isAX3 ? 26 : 20 }
    private var isDraftBlank: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sendButton: some View {
        Button(action: sendTapped) {
            Group {
                if store.sendState.isSubmitting {
                    ProgressView().tint(Color.lsOnAccent)
                } else {
                    Image(systemName: "arrow.up").font(.system(size: sendIconSize, weight: .semibold))
                        .foregroundStyle(Color.lsOnAccent)
                }
            }
            .frame(width: sendButtonSize, height: sendButtonSize)
            .background(isDraftBlank ? Color.lsAccent.opacity(0.4) : Color.lsAccent, in: Circle())
        }
        .disabled(isDraftBlank || store.sendState.isSubmitting)
        .accessibilityIdentifier(QAAccessibilityID.commentSendButton)
        .accessibilityLabel("送出留言")
    }

    private func sendTapped() {
        guard !isDraftBlank, let viewerUserID = familyStore.ownerUserID else { return }
        let body = draft
        let authorDisplayName = familyStore.members.first { $0.userID == viewerUserID }?.displayName ?? "我"
        Task {
            let success = await store.send(body: body, authorID: viewerUserID, authorDisplayName: authorDisplayName)
            if success {
                draft = ""
                draftSendSucceededTick += 1
            } else if case .failure(let error) = store.sendState {
                sendError = error
            }
        }
    }
}
