import SwiftUI

/// LS-18 / 06d 已送出申請 · 等待核准。版式依 `design/littlesprout.pen` frame `W4aNW`：狀態卡
/// （單據，0 角托）→「接下來會發生什麼」三行預告表 → 主要動作（「知道了，等通知」）→ 撤回。
///
/// 輪詢（票文 Scope 第 2 點）：`.task` 每 4 秒呼叫一次 `get_my_join_request`，依
/// `JoinWaitingPhase.pollOutcome` 決定核准（呼叫 `refreshMyFamily()`，root routing 自動離開
/// 三岔路，見 `FamilyStore` 文件）或回三岔路（拒絕／撤回／這筆申請查不到了——三種情況對申請人
/// 都是「沒有任何殘留權限」，統一處理）。核准前使用者完全看不到任何家庭內容：這個畫面本身不讀
/// 任何 `families`／`albums`／`media` 等表，root routing 也要等 `myFamily` 非 nil 才會切換離開
/// 三岔路，不存在「看得到卻還沒核准」的中間態。
struct JoinWaitingView: View {
    let familyStore: FamilyStore
    @Binding var path: [FamilyOnboardingRoute]
    let requestID: UUID
    let familyID: UUID
    let familyName: String
    let submittedAt: Date

    private static let pollInterval: Duration = .seconds(4)

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                upperSection
                Spacer(minLength: AppSpacing.block)
                footerSection
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, 12)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { await pollLoop() }
    }

    // MARK: - Upper

    private var upperSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            header
            statusCard
            nextStepsNote
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("申請已送出")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("邀請碼沒問題。接下來等「\(familyName)」的管理者按下核准。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("加入申請")
                .appFont(.meta, weight: .bold)
                .tracking(2)
                .foregroundStyle(Color.lsTextSecondary)
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "checkmark.circle.fill")
                    .appIconFrame(.large)
                    .foregroundStyle(Color.lsSuccess)
                Text("已送到管理者手上")
                    .appFont(.lead, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
            }
            Text("核准後你就能看到「\(familyName)」的照片和日記，我們也會通知你。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            metaRow(label: "申請加入", value: familyName)
            metaRow(label: "送出時間", value: formattedSubmittedAt)
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label).appFont(.note).foregroundStyle(Color.lsTextSecondary)
            Spacer()
            Text(value).appFont(.note, weight: .semibold).foregroundStyle(Color.lsTextPrimary)
        }
    }

    private var nextStepsNote: some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Text("接下來會發生什麼")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            nextStepsRow(label: "送出後", value: "家長會收到通知")
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            nextStepsRow(label: "他按核准", value: "你才進得到家庭裡")
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            nextStepsRow(label: "為什麼", value: "擋下拿到碼的陌生人")
        }
        .padding(AppSpacing.group)
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
    }

    private func nextStepsRow(label: String, value: String) -> some View {
        HStack {
            Text(label).appFont(.note, weight: .semibold).foregroundStyle(Color.lsTextSecondary)
            Spacer()
            Text(value)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            PrimaryButton(icon: "bell", title: "知道了，等通知", action: dismissToFork)
            Button(action: withdraw) {
                HStack(spacing: AppSpacing.tight) {
                    Image(systemName: "arrow.uturn.backward").appIconFrame(.small)
                    Text("撤回這次申請").appFont(.body, weight: .semibold)
                }
                .foregroundStyle(Color.lsDanger)
                .padding(.vertical, AppSpacing.controlPaddingTap)
            }
            Text("撤回後可以重新輸入邀請碼再申請一次。")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var formattedSubmittedAt: String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: submittedAt)
        let minute = calendar.component(.minute, from: submittedAt)
        let time = String(format: "%02d:%02d", hour, minute)
        if calendar.isDateInToday(submittedAt) { return "今天 \(time)" }
        if calendar.isDateInYesterday(submittedAt) { return "昨天 \(time)" }
        let month = calendar.component(.month, from: submittedAt)
        let day = calendar.component(.day, from: submittedAt)
        return "\(month)/\(day) \(time)"
    }

    // MARK: - Actions

    private func dismissToFork() {
        path = []
    }

    private func withdraw() {
        Task {
            guard await familyStore.withdrawJoinRequest(requestID: requestID) else { return }
            path = []
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let result = await familyStore.refreshMyJoinRequest()
            switch JoinWaitingPhase.pollOutcome(for: result, expectedRequestID: requestID) {
            case .stillWaiting:
                break
            case .approved:
                await familyStore.refreshMyFamily()
                return
            case .returnToFork:
                path = []
                return
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        JoinWaitingView(
            familyStore: .preview(),
            path: .constant([]),
            requestID: UUID(),
            familyID: UUID(),
            familyName: "陳家",
            submittedAt: Date()
        )
    }
}
#endif
