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
                // LS-237 修（池 `d17bed11` i3）：無條件 `draft = ""` 會在「送出往返期間使用者
                // 又打了新字」時把新字一併清掉（`body` 已在按下當下正確快照，只差清空這一步沒
                // 比對是否仍是同一份草稿）——只有草稿沒被改過才清空。
                if draft == body { draft = "" }
                draftSendSucceededTick += 1
                syncCommentCountIfKnown()
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

    /// LS-237 修（池 `d17bed11` i4）：`sendTapped()` 用的是 unstructured `Task`，sheet 若在
    /// 送出仍在飛行中被關閉，`CommentsSheetView.body` 的 `.onChange(of: store.knownExactCount)`
    /// 已經隨 View 卸載、不會再觸發——這次送出造成的計數變化本來要等下次重開同一則留言 sheet
    /// 才會同步回互動列（無資料遺失：送出本身仍在背景完成，只有「回報計數」這一步被錯過）。
    /// 兩種修法擇一：(a) 改用可取消的 `Task` 存到 `@State`、`.onDisappear` 呼叫 `cancel()`；
    /// (b) 送出完成後直接回寫 `TimelineStore`。這裡選 (b)：(a) 會讓「使用者關閉 sheet 時送出
    /// 仍在飛行中」這個情境從「送出仍會完成」退化成「留言真的送不出去」（`cancel()` 會連
    /// `store.send()` 本身的網路呼叫一起中止），比原本的小落差更嚴重；(b) 不改變送出本身的
    /// 行為，只是把「回報計數」這一步從倚賴 View 是否還在畫面上，改成直接呼叫
    /// `timelineStore`（這個 View 之外的長生命週期物件，同 `AlbumsStore` 之於
    /// `AlbumDetailView` 的角色）。抽成 internal 方法（同 `CommentsSheetView
    /// .headCommentCountText` 既有慣例）方便單元測試：不需要真的把 View 安裝到畫面上，直接
    /// 建構值就能呼叫並驗證。`.onChange` 仍保留給「使用者還在畫面上、`loadEarlier()` 之類的
    /// 其他路徑改變 `knownExactCount`」的一般情況，兩者不衝突（都只是把同一個值寫進
    /// `timelineStore`，重複寫入是無害的 no-op）。
    func syncCommentCountIfKnown() {
        guard let count = store.knownExactCount else { return }
        timelineStore.setCommentCount(count, forKey: targetKey)
    }
}
