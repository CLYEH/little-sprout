import SwiftUI
import UIKit

/// LS-18 / 06 輸入邀請碼（含 06b 已過期／06c 次數用盡）。版式依 `design/littlesprout.pen`
/// frame `VCMrA`（06）／`gCeDF`（06b）／`Gp3Sl`（06c）／`hKSu1`（AX3，文案逐字相同）：
/// Header → 邀請碼卡（六格＋錯誤態判決句）→ 說明區（依狀態切換）→ 主要動作 → Footer（貼上
/// 邀請連結，跨狀態皆存在）。Upper／Footer 兩段式 flex spacer 對齊 `CreateFamilyView` 既有寫法
/// （見該檔文件註解）。
struct JoinCodeView: View {
    let familyStore: FamilyStore
    @Binding var path: [FamilyOnboardingRoute]

    @State private var code: String
    @State private var keyboard = KeyboardHeightObserver()
    @State private var pasteFeedback: String?
    // R1（同 InviteFamilyView copiedFeedbackTask）：離開畫面時取消還沒到期的回饋 Task，不要在
    // 使用者已經看不到這個畫面時還跑一個空等幾秒才清狀態的殘留 Task。
    @State private var pasteFeedbackTask: Task<Void, Never>?

    init(familyStore: FamilyStore, path: Binding<[FamilyOnboardingRoute]>, initialCode: String = "") {
        self.familyStore = familyStore
        self._path = path
        _code = State(initialValue: InviteCodeField.normalize(initialCode))
    }

    private var phase: JoinCodeFormPhase {
        JoinCodeFormPhase(requestJoinState: familyStore.requestJoinState)
    }

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    private var remainingCount: Int { max(0, 6 - code.count) }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                upperSection
                Spacer(minLength: AppSpacing.block)
                footerSection
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, 16)
        }
        // LS-105 既有慣例（見 OTPVerificationView／EmailSignInView）：隱形 TextField 承接輸入時，
        // ScrollView 本身不會因鍵盤出現自動收縮可視範圍，補這行讓底界跟著鍵盤收縮。
        .contentMargins(.bottom, keyboard.height, for: .scrollContent)
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { familyStore.resetRequestJoinState() }
        .onChange(of: code) { _, _ in
            // 使用者開始修正輸入就把上一次的錯誤視覺清掉——同 CreateFamilyView
            // `showsEmptyNameMessage` 隨輸入變動清除的既有慣例。
            familyStore.resetRequestJoinState()
        }
        .onDisappear { pasteFeedbackTask?.cancel() }
    }

    // MARK: - Upper

    private var upperSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            header
            codeCard
            switch phase {
            case .idle, .submitting:
                explainSection
                if remainingCount > 0 {
                    pressReply
                }
                submitButton
            case .genericError:
                explainSection
                submitButton
            case .expired, .exhausted:
                Text(policyNoteText)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                shareForNewCodeButton
                Text(prewrittenNoteText)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("輸入邀請碼")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            if !phase.isError {
                Text("6 位英數字，分前三碼、後三碼。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
    }

    private var codeCard: some View {
        VStack(spacing: AppSpacing.group) {
            InviteCodeField(code: $code, isError: phase.isError)
            if phase.isError {
                errorRow
            } else {
                Text("英文字母不分大小寫")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsPaperEdge, lineWidth: 1)
        )
    }

    private var errorRow: some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsDanger)
            Text(errorHeadline)
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsDanger)
        }
    }

    private var explainSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("請家人在 App 裡點「邀請家人」，把 6 位碼傳給你。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
            Text("送出後家人會收到通知，他核准你就進得來。")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var pressReply: some View {
        HStack(spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextPrimary)
            Text("還要再填 \(remainingCount) 個字")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    private var submitButton: some View {
        PrimaryButton(
            icon: "paperplane.fill",
            title: "送出加入申請",
            isLoading: isSubmitting,
            loadingTitle: "正在送出申請…",
            action: submit
        )
    }

    /// 06b／06c 的主要動作是「傳訊息跟家人要新的」，不是重送同一支已經確定過期／用盡的碼
    /// ——樣式沿用 `InviteFamilyView` 既有 `ShareLink` 主鍵手刻寫法（見該檔 `.generated` case）。
    private var shareForNewCodeButton: some View {
        ShareLink(item: prewrittenMessage) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "paperplane.fill").appIconFrame(.medium)
                Text("傳訊息跟家人要新的").appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.controlPaddingCTA)
            .background(Color.lsAccent, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            SecondaryButton(icon: "link", title: "改用貼上邀請連結", action: pasteFromClipboard)
            if let pasteFeedback {
                Text(pasteFeedback)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        }
    }

    // MARK: - Copy

    private var errorHeadline: String {
        switch phase {
        case .expired: "這組邀請碼已經過期了。"
        case .exhausted: "這組邀請碼的次數用完了。"
        case .genericError(let error): error.userFacingMessage
        case .idle, .submitting: ""
        }
    }

    private var policyNoteText: String {
        switch phase {
        case .expired: "邀請碼從產生那天算 7 天。"
        case .exhausted: "一組邀請碼最多 5 位家人可以用，避免被轉傳出去。"
        case .idle, .submitting, .genericError: ""
        }
    }

    private var prewrittenMessage: String {
        switch phase {
        case .expired: "我的邀請碼過期了，可以再產生一組新的給我嗎？"
        case .exhausted: "邀請碼的名額用完了，可以再產生一組新的給我嗎？"
        case .idle, .submitting, .genericError: ""
        }
    }

    private var prewrittenNoteText: String {
        "按下後會開啟訊息，內容先幫你寫好：「\(prewrittenMessage)」"
    }

    // MARK: - Actions

    private func submit() {
        guard code.count == 6, !isSubmitting else { return }
        Task { await performSubmit() }
    }

    /// `request_join` 回傳 `.pending` 時只帶 `request_id`／`family_id`（見
    /// `SupabaseFamilyAPIClient.RequestJoinRow`），沒有 `family_name`——06d 的「等『陳家』核准」
    /// 需要這個名字，這裡多打一次 `get_my_join_request()`（申請成立當下已經寫入，查得到）拿
    /// 完整資訊，而不是另外幫 `request_join` 加一個回傳欄位（那支 RPC 的簽章不在本票改動範圍）。
    private func performSubmit() async {
        guard let outcome = await familyStore.requestJoin(code: code) else { return }
        switch outcome {
        case .joined:
            break // FamilyStore 已在內部呼叫 refreshMyFamily()，root routing 會自動離開三岔路。
        case .pending(let requestID, let familyID):
            let myRequest = await familyStore.refreshMyJoinRequest()
            path.append(.joinWaiting(
                requestID: requestID,
                familyID: familyID,
                familyName: myRequest?.familyName ?? "",
                submittedAt: myRequest?.createdAt ?? Date()
            ))
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, let parsed = InviteCodeParser.extractCode(from: text) else {
            showPasteFeedback("剪貼簿裡沒看到邀請碼或連結，請確認家人傳的內容。")
            return
        }
        familyStore.resetRequestJoinState()
        code = InviteCodeField.normalize(parsed)
        showPasteFeedback(nil)
    }

    private func showPasteFeedback(_ message: String?) {
        pasteFeedbackTask?.cancel()
        pasteFeedback = message
        guard message != nil else { return }
        pasteFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pasteFeedback = nil
        }
    }
}

#if DEBUG
#Preview("空") {
    NavigationStack {
        JoinCodeView(familyStore: .preview(), path: .constant([]))
    }
}
#endif
