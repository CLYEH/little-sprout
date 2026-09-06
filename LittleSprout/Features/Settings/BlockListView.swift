import SwiftUI

/// 封鎖名單（LS-189，依 LS-152 稿 `CmZsg`）——列出目前封鎖的成員（`blocked_users`，
/// `blocker_id = 我`），可解除封鎖。取代 LS-188 的最小佔位（見該檔沿革）。
///
/// 顯示名稱／頭像從 `familyStore.members` 解析（同 `contentActions` 呼叫端的既有理由，見
/// `DiaryDetailView+ContentActions.swift`）——`blocked_users` 本身沒有內嵌 profile 欄位，也不
/// 額外發一支 profiles 查詢；被封鎖者若已經離開家庭（不在 `members` 清單裡）顯示通用標籤
/// 「這位成員」，不是錯誤狀態。
struct BlockListView: View {
    let familyStore: FamilyStore
    let safetyAPIClient: SafetyAPIClient
    /// LS-189 R2（merge-review R1 B2）：解除封鎖成功後重抓時間軸，讓對方的內容重新出現——
    /// 同 `DiaryDetailView+ContentActions.memberBlocked()` 的既有理由，這裡是反方向（解除
    /// 而不是封鎖），見 `unblockTarget` 的 `onSuccess` 呼叫端。
    let timelineStore: TimelineStore

    @State private var loadState: TimelineOperationState = .idle
    @State private var blockedUsers: [BlockedUserRecord] = []
    @State private var unblockTarget: BlockedUserRecord?

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
        .sheet(item: $unblockTarget) { target in
            UnblockConfirmSheet(
                familyID: familyStore.myFamily?.id ?? UUID(), memberName: displayName(for: target.blockedID),
                blockedID: target.blockedID, safetyAPIClient: safetyAPIClient,
                onUnblocked: {
                    blockedUsers.removeAll { $0.blockedID == target.blockedID }
                    Task { await timelineStore.refreshWithCurrentFilter() }
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("封鎖名單")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("你封鎖的人看不到通知，也不受影響；只有你看不到他們的內容。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .submitting:
            if blockedUsers.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                card
            }
        case .failure(let error):
            errorRow(error)
        case .success:
            if blockedUsers.isEmpty {
                emptyState
            } else {
                card
            }
        }
    }

    private var card: some View {
        SettingsCard {
            ForEach(Array(blockedUsers.enumerated()), id: \.element.id) { index, blocked in
                if index > 0 { SettingsRowDivider() }
                blockedRow(blocked)
            }
        }
    }

    private func blockedRow(_ blocked: BlockedUserRecord) -> some View {
        HStack(spacing: AppSpacing.group) {
            ChildAvatarView(
                name: displayName(for: blocked.blockedID), size: 48,
                avatarURL: familyStore.avatarDisplayURL(rawValue: avatarURL(for: blocked.blockedID))
            )
            Text(displayName(for: blocked.blockedID))
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
            Spacer(minLength: AppSpacing.group)
            unblockButton(blocked)
        }
        .padding(AppSpacing.insetCard)
    }

    private func unblockButton(_ blocked: BlockedUserRecord) -> some View {
        Button {
            unblockTarget = blocked
        } label: {
            Text("解除封鎖")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .padding(.horizontal, AppSpacing.item)
                // merge-review 實測：`minHeight: 44` 量到 43.9x（`%.1f` 顯示成「44.0」但仍
                // < 44，`tap-target-check.sh` 用 `<` 比較會判定違規）——改 48 留緩衝（同硬約束
                // 「minHeight ≥48」的既有理由，即使不是 sheet 內元件，這裡經驗證同樣需要）。
                .frame(minHeight: 48)
                .background(Color.lsSurface2, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "沒有封鎖任何人",
            systemImage: "person.fill.xmark",
            description: Text("你目前沒有封鎖家庭裡的任何成員。")
        )
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

    private func displayName(for userID: UUID) -> String {
        familyStore.members.first { $0.userID == userID }?.displayName ?? "這位成員"
    }

    private func avatarURL(for userID: UUID) -> String? {
        familyStore.members.first { $0.userID == userID }?.avatarURL
    }

    private func load() async {
        guard let familyID = familyStore.myFamily?.id else { return }
        loadState = .submitting
        do {
            blockedUsers = try await safetyAPIClient.listBlockedUsers(familyID: familyID)
            loadState = .success
        } catch {
            loadState = .failure(AppError.map(error))
        }
    }
}

/// 06 解除封鎖確認——沿用 `DeleteConfirmationSheet` 通用版式（非危險動作，圖示用
/// `person.crop.circle.badge.checkmark`；稿面 `CmZsg` 只畫了列上的「解除封鎖」鈕，未另外畫確認
/// 卡，這裡比照其餘不可逆／有感知後果動作一律先確認的既有慣例（`FamilyMembersView+Sheets.swift`
/// 轉移／移除成員皆先confirm），避免手滑誤觸解除）。
private struct UnblockConfirmSheet: View {
    let familyID: UUID
    let memberName: String
    let blockedID: UUID
    let safetyAPIClient: SafetyAPIClient
    var onUnblocked: () -> Void = {}

    var body: some View {
        DeleteConfirmationSheet(
            headTitle: "要解除封鎖「\(memberName)」嗎？",
            bodyText: "解除後，你會重新看到這位成員的照片、日記與留言。",
            confirmLabel: "解除封鎖",
            confirmIcon: "person.crop.circle.badge.checkmark",
            confirmAction: { try await safetyAPIClient.unblockUser(familyID: familyID, blockedID: blockedID) },
            onSuccess: onUnblocked,
            // LS-189 R2（merge-review R1 B4）：同 `BlockConfirmSheet` 的既有理由——42501 實際
            // 語意是「已經不是該家庭成員」，不是「沒有權限刪除」。
            errorCopy: { error in
                guard case .rejected(_, let code) = error, code == "42501" else { return error.userFacingMessage }
                return "你沒有權限解除封鎖。"
            }
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        BlockListView(familyStore: .preview(), safetyAPIClient: PreviewSafetyAPIClient(), timelineStore: .preview())
    }
}
#endif
