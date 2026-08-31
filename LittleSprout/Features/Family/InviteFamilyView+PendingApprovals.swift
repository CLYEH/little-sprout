import SwiftUI

/// LS-108 Owner 審核清單：`list_join_requests`（display_name／avatar 二欄）＋核准／拒絕。版式
/// 依 `design/littlesprout.pen` frame `NRLL3`（07b）的「Sec 待核准」段落，只在 `.generated`
/// 態、且有待審申請時出現（見 `InviteFamilyView.body` 呼叫處：pending 申請只可能掛在一支仍然
/// 有效的邀請碼下，`.empty` 狀態下不會有殘留待審申請，見該處註解）。
///
/// 拆成獨立檔案：`InviteFamilyView.swift` 已經逼近 SwiftLint `file_length` 上限（同其餘
/// `InviteFamilyView+*`／`FamilyStore+*` 拆檔理由）。
///
/// 通知進場點（票文 Scope 第 4 點「通知進場點沿用既有推播骨架」）：目前 repo 沒有任何推播
/// UI（LS-22 Edge Function 只做資料層彙總，見 docs/API.md §3 `notification_events`），本票不做
/// ——owner 只能靠自己開這個畫面看到新申請，沒有推播提示，見 handoff 未完成欄（記入待辦池，
/// 需要時再另開一張新票）。
extension InviteFamilyView {
    @ViewBuilder
    var pendingApprovalsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            pendingApprovalsHeader
            if let error = familyStore.joinRequestActionError {
                pendingApprovalActionErrorRow(error)
                    .padding(.horizontal, AppSpacing.insetCard)
                    .padding(.bottom, AppSpacing.group)
            }
            ForEach(Array(familyStore.pendingJoinRequests.enumerated()), id: \.element.requestID) { index, request in
                if index > 0 {
                    Rectangle().fill(Color.lsBorder).frame(height: 1)
                }
                pendingApplicantRow(request, isOldest: index == 0)
            }
        }
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsControlLine, lineWidth: 2)
        )
    }

    private var pendingApprovalsHeader: some View {
        HStack {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "person.fill.checkmark")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("等你決定")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            Spacer()
            HStack(spacing: 2) {
                Text("\(familyStore.pendingJoinRequests.count)")
                    .appFont(.note, weight: .bold)
                    .foregroundStyle(Color.lsTextSecondary)
                Text("位")
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.vertical, AppSpacing.tight)
            .padding(.horizontal, AppSpacing.group)
            .background(Color.lsSurface2, in: Capsule())
        }
        .padding(.horizontal, AppSpacing.insetCard)
        .padding(.top, AppSpacing.item)
        .padding(.bottom, AppSpacing.group)
    }

    private func pendingApprovalActionErrorRow(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsDanger)
            Text(error.userFacingMessage)
                .appFont(.note)
                .foregroundStyle(Color.lsDanger)
        }
    }

    /// `isOldest`：`list_join_requests` 依 `created_at` 由舊到新排序（見 docs/API.md §4），
    /// 陣列第一筆就是等最久的那位——只有他掛「等最久」膠囊（票文與 `NRLL3` 設計一致）。
    private func pendingApplicantRow(_ request: PendingJoinRequest, isOldest: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            HStack(spacing: AppSpacing.group) {
                applicantAvatar(request)
                Text(request.displayName)
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            HStack(spacing: AppSpacing.group) {
                if isOldest {
                    Pill(icon: "hourglass", text: "等最久")
                }
                Text(JoinRequestTimeFormatter.format(request.createdAt))
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            SecondaryButton(
                icon: "checkmark",
                title: "核准，讓\(request.displayName)加入",
                action: { approve(request) }
            )
            .disabled(familyStore.isProcessingJoinRequest(request.requestID))
            Button {
                reject(request)
            } label: {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "xmark").appIconFrame(.small)
                    Text("拒絕這個申請").appFont(.body, weight: .semibold)
                }
                .foregroundStyle(Color.lsDanger)
            }
            .disabled(familyStore.isProcessingJoinRequest(request.requestID))
        }
        .padding(AppSpacing.insetCard)
    }

    /// `avatar_url` 有值就載入（`profiles.avatar_url` 來自 OAuth provider 的公開頭像網址，不是
    /// 簽名 URL，見 docs/API.md §3 `profiles`），失敗或沒有值就退回姓名首字——同
    /// `FamilyPreviewCard`／既有頭像類元件「先給占位、圖到了再蓋上去」的既有慣例。
    @ViewBuilder
    private func applicantAvatar(_ request: PendingJoinRequest) -> some View {
        ZStack {
            Circle().fill(Color.lsAccent.opacity(0.15))
            if let avatarURLString = request.avatarURL, let url = URL(string: avatarURLString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        applicantInitial(request)
                    }
                }
            } else {
                applicantInitial(request)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }

    private func applicantInitial(_ request: PendingJoinRequest) -> some View {
        Text(String(request.displayName.prefix(1)))
            .appFont(.body, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
    }

    private func approve(_ request: PendingJoinRequest) {
        Task { await familyStore.approveJoinRequest(request.requestID) }
    }

    private func reject(_ request: PendingJoinRequest) {
        Task { await familyStore.rejectJoinRequest(request.requestID) }
    }
}
