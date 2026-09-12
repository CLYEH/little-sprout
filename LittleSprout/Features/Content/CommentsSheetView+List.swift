import SwiftUI

/// LS-218：留言清單本體——「載入更早的留言」（票文範圍 2）＋逐則留言列＋送出後捲到底（票文
/// 範圍 3）。拆到獨立檔案的理由見 `CommentsSheetView.swift` 檔頭註解。
extension CommentsSheetView {
    var commentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                    if store.hasEarlier {
                        loadEarlierButton
                    }
                    ForEach(store.comments) { comment in
                        commentRow(comment).id(comment.id)
                    }
                }
            }
            .task(id: store.initialLoadState) {
                guard store.initialLoadState == .success else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: draftSendSucceededTick) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.comments.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var loadEarlierButton: some View {
        HStack {
            Spacer(minLength: 0)
            Group {
                if store.loadEarlierState.isSubmitting {
                    ProgressView()
                } else {
                    Button {
                        Task { await store.loadEarlier() }
                    } label: {
                        Text("載入更早的留言")
                            .appFont(.note, weight: .semibold)
                            .foregroundStyle(Color.lsAccent)
                            .padding(.vertical, AppSpacing.item)
                            .padding(.horizontal, AppSpacing.item)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(QAAccessibilityID.commentLoadEarlierButton)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func commentRow(_ comment: CommentRecord) -> some View {
        Button {
            rowTapped(comment)
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.group) {
                ProfilePrintChip(size: avatarSize)
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    HStack(spacing: AppSpacing.tight) {
                        Text(comment.authorDisplayName).appFont(.note, weight: .semibold)
                            .foregroundStyle(Color.lsTextPrimary)
                        Text("·").appFont(.note).foregroundStyle(Color.lsTextSecondary)
                        Text(JoinRequestTimeFormatter.format(comment.createdAt))
                            .appFont(.note).foregroundStyle(Color.lsTextSecondary)
                    }
                    Text(comment.body)
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isRowActionsReady)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(QAAccessibilityID.commentRow(id: comment.id.uuidString))
        .accessibilityHint("開啟這則留言的操作選項")
    }
}
