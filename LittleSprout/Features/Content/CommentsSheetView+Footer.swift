import SwiftUI

/// LS-218：輸入列——單行成長 `TextField`＋送出鈕（畫面唯一 `$accent`；48／AX3 56，merge-review
/// R1 m5 從稿面下限值 44 調整為 48，見 `sendButtonSize` 文件註解；空白時 disabled，票文範圍
/// 3）。拆到獨立檔案的理由見 `CommentsSheetView.swift` 檔頭註解。
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

    // merge-review R1 m5：44 是設計稿的下限、不是上限——同家族 `ContentActionsSheet`／
    // `DeleteConfirmationSheet`／`CommentsSheetView+States.swift` 的「關閉」鈕都已經改用
    // `minHeight: 48`（`TapTargetGateTests.swift` 註解：iOS 26.2+ sheet 縮放緩衝，實測
    // ≈0.9602 縮放下 44×0.9602≈42.25 < 44）。這裡跟進沿用 48（AX3 56 遠高於下限不受影響），
    // 讓所有留言 sheet 內的可點元件享有同一個緩衝，不留這一顆例外——reviewer 已確認目前 CI
    // 釘住的 iOS 26.2 量到剛好 44.0pt、還沒有真的踩到，這是防禦性一致化，不是修一個已知失敗。
    private var sendButtonSize: CGFloat { isAX3 ? 56 : 48 }
    private var sendIconSize: CGFloat { isAX3 ? 26 : 20 }
    private var isDraftBlank: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// merge-review R1 m4：送出鈕是否可以按——`sendTapped()` guard 條件的鏡像（同
    /// `isRowActionsReady`／`DiaryDetailView+ContentActions.isContentActionsReady` 既有先例）：
    /// 冷啟動 `familyStore.ownerUserID` 還沒填好時，原本按下送出鈕完全沒反應。
    private var isSendReady: Bool { familyStore.ownerUserID != nil }

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
        .disabled(isDraftBlank || store.sendState.isSubmitting || !isSendReady)
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
            } else if case .failure(let error) = store.sendState,
                      !CommentsErrorPresentation.make(from: error).isTargetGone {
                // merge-review R1 m3：LS026（目標已刪）已經由 `targetGoneError` 把整張 sheet
                // 換成單一「關閉」鈕的終態（`CommentsSheetView.swift` targetGoneError／
                // `+States.swift` targetGoneState）——這裡不能再疊一層 alert，否則使用者會同時
                // 看到 alert 與終態畫面。只有非 LS026 的送出失敗（網路／其他錯誤）才彈 alert。
                sendError = error
            }
        }
    }
}
