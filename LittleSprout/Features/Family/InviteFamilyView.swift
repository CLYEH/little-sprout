import SwiftUI
import UIKit

/// LS-18 / 07 邀請家人（空／載入／已產生三態，含 07a／07c）。版式依
/// `design/littlesprout.pen` frame `z6DOE`（07a）／`CHLio`（07c）／`kcGJa`（07）：Header →
/// 狀態相關的視覺卡 → 角色列（互動選擇／唯讀狀態，見 LS-111）→（已產生／載入才有）
/// `ApprovalStatusRow` → 次要動作（複製碼／名額文案）→（owner 有待審申請才有）審核清單
/// （LS-108，見 `InviteFamilyView+PendingApprovals.swift`）→ 破壞性重新產生區 → 釘底 Action Bar
/// （LS-111 R6 起「畫面有且僅有一顆貫穿全狀態主 CTA」的釘底動作帶慣例：hairline ＋ 依狀態變化
/// 的主要動作，`.safeAreaInset(edge: .bottom)`，內容區維持可捲動）。
///
/// 角色（member／viewer）選擇（LS-111 併入本票落地，取代 R2 未經審過的陽春版）：互動列
/// （07a）依 `cmp/Role Section` 現況設計——未選中列透明躺在背景上，選中列浮起一張
/// `$print-paper` 紙（沖印品母題延伸到 UI 元件，四通道編碼：icon 語意圖示 pencil/eye＋絕對定位
/// checkmark＋字重 700/600＋紙面 vs 透明背景）；已產生／載入態（07／07c）改用唯讀
/// `cmp/Role Status` 單列，顯示這支邀請碼實際烘焙進去的角色，要換角色只能走「重新產生」。
struct InviteFamilyView: View {
    let familyStore: FamilyStore

    // LS-111：不是 `private`——`InviteFamilyView+Role.swift`（另一個檔案的 extension）需要讀寫
    // 它，理由同該檔文件註解。
    @State var selectedRole: FamilyRole = .member
    @State private var showsRegenerateConfirmation = false
    @State var showsCopiedFeedback = false
    // R1 F10：兩秒內連按兩次「複製邀請碼」，第一個 Task 到期時會把第二次的「已複製！」提前
    // 清掉；離開畫面時前一次的 Task 也該跟著取消，不要在使用者已經看不到這個畫面時還跑一個
    // 空等兩秒才把 `@State` 改回去的殘留 Task。
    @State private var copiedFeedbackTask: Task<Void, Never>?

    /// R2 N1：狀態計算搬去獨立、可單元測試的 `InvitePhase`（見該檔文件註解）。
    var phase: InvitePhase {
        InvitePhase(
            lookupInviteState: familyStore.lookupInviteState,
            createInviteState: familyStore.createInviteState,
            latestInvite: familyStore.latestInvite
        )
    }

    /// 查詢失敗（`InvitePhase.lookupFailed`）或建立失敗（`createInviteState`）都要顯示同一顆
    /// `errorRow`——R2 N1：兩者現在是分開的狀態，這裡合併成單一顯示條件，畫面上同時只會有
    /// 一種失敗（互斥，見 `FamilyStore` 兩支方法的 guard）。
    private var currentError: AppError? {
        if case .lookupFailed(let error) = phase { return error }
        if case .failure(let error) = familyStore.createInviteState { return error }
        return nil
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                visualCard
                    .padding(.top, AppSpacing.item)
                if let error = currentError {
                    errorRow(error)
                        .padding(.top, AppSpacing.item)
                }
                if case .empty = phase {
                    interactiveRoleSection
                        .padding(.top, AppSpacing.section)
                }
                if phase.showsDestructiveSection {
                    roleStatusSection
                        .padding(.top, AppSpacing.block)
                    ApprovalStatusRow()
                        .padding(.top, AppSpacing.section)
                    secondaryActionsSection
                        .padding(.top, AppSpacing.section)
                    if !familyStore.pendingJoinRequests.isEmpty {
                        pendingApprovalsSection
                            .padding(.top, AppSpacing.section)
                    }
                    destructiveSection
                        .padding(.top, AppSpacing.section)
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.item)
        }
        .safeAreaInset(edge: .bottom) { actionBarContainer }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            familyStore.resetCreateInviteState()
            // R1 F4：進場先查這個家庭現有有沒有一支還有效的邀請碼，顯示既有碼而非空狀態
            // ——避免每次重開 app 都讓使用者以為自己沒有邀請碼、再產生一支新的。LS-108：順帶
            // 查一次待審清單（owner 審核，見 `InviteFamilyView+PendingApprovals.swift`）。
            Task {
                await familyStore.refreshLatestInvite()
                await familyStore.refreshPendingJoinRequests()
            }
        }
        .onDisappear {
            copiedFeedbackTask?.cancel()
        }
        .confirmationDialog(
            "重新產生邀請碼？",
            isPresented: $showsRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("重新產生", role: .destructive, action: generate)
            Button("取消", role: .cancel) {}
        } message: {
            Text("舊的邀請碼就不能再用了。已經拿到舊邀請碼的家人，要再跟你要一次新的。")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text(headerTitle)
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text(headerSubtitle)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var headerTitle: String {
        switch phase {
        case .empty, .checkingExisting, .lookupFailed: "邀請家人一起看"
        case .generating, .generated: "邀請家人"
        }
    }

    private var headerSubtitle: String {
        let familyName = familyStore.myFamily?.name ?? ""
        switch phase {
        case .empty:
            return "把邀請碼給家人，他們輸入後向你送出申請，你核准就能一起看「\(familyName)」的照片和日記。"
        case .checkingExisting:
            // R2 N1：進場先查這個家庭有沒有既有邀請碼——沒有對應的 .pen 設計稿，是純技術性
            // 的查詢等待（同 RootView.FamilyLookupFailedView 的兜底定位），不套用「產生中」
            // 07c 的沖印品母題視覺。
            return "正在確認你的家庭有沒有邀請碼，請稍等一下。"
        case .lookupFailed:
            return "查詢邀請碼時發生問題，請重試一次。"
        case .generating:
            return "正在為你產生一組新的邀請碼。通常幾秒鐘就好，請稍等一下。"
        case .generated:
            return "把邀請碼給家人，他們輸入後向你送出申請，你核准就完成。"
        }
    }

    // MARK: - Visual card（依狀態切換）

    @ViewBuilder
    private var visualCard: some View {
        switch phase {
        case .checkingExisting:
            // 沒有對應設計稿的純技術等待態——沿用 `codeCardShell` 骨架但只放一個系統
            // `ProgressView`，不冒充 07c「產生中」的沖印品視覺（那是使用者主動觸發的動作，
            // 這裡是進場自動查詢）。
            codeCardShell {
                ProgressView()
                Text("正在確認邀請碼…")
                    .appFont(.meta, weight: .bold)
                    .tracking(2)
                    .foregroundStyle(Color.lsTextSecondary)
            }
        case .empty, .lookupFailed:
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                PrintPhotoCard(
                    photoHeight: 194,
                    cornerSize: 26,
                    mountPoolOpacity: .inviteSample,
                    showsImprint: false,
                    imageName: "InviteGrandma",
                    accessibilityLabel: "家人在陽台上開心互動的合照"
                )
                HStack(spacing: AppSpacing.label) {
                    Pill(icon: "eye", text: "範例")
                    Text("家人核准之後看到的就是這些")
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextSecondary)
                }
            }
        case .generating:
            codeCardShell {
                Text("正在產生邀請碼…")
                    .appFont(.meta, weight: .bold)
                    .tracking(2)
                    .foregroundStyle(Color.lsTextSecondary)
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .fill(Color.lsSurface2)
                    .frame(width: 256, height: 60)
                HStack(spacing: AppSpacing.label) {
                    Capsule().fill(Color.lsSurface2).frame(width: 122, height: 41)
                    Capsule().fill(Color.lsSurface2).frame(width: 133, height: 41)
                }
            }
        case .generated(let invite):
            codeCardShell {
                Text("邀請碼")
                    .appFont(.meta, weight: .bold)
                    .tracking(2)
                    .foregroundStyle(Color.lsTextSecondary)
                // LS-107 R1 M1（`4b6ee413`）：雙 `Text` 各自縮放不同步（實測差 6.8%），改單一 `Text`。
                Text(formattedCode(invite.code))
                    .appNumericFont(.code, weight: .bold)
                    .tracking(4)
                    .foregroundStyle(Color.lsTextPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: AppSpacing.label) {
                    Pill(icon: "calendar", text: "\(formattedExpiry(invite.expiresAt)) 到期")
                    // R1 F4：過去這裡直接顯示 maxUses，永遠不會反映真的用掉幾次；
                    // `remainingUses` 從 F4 反查回來的 `usedCount` 算出真實剩餘量。
                    Pill(icon: "person.2", text: "還可用 \(invite.remainingUses) 次")
                }
            }
        }
    }

    private func codeCardShell(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: AppSpacing.item) {
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
    }

}

// MARK: - R1（SwiftLint `type_body_length`）：以下皆抽成 extension，理由同 `WelcomeView` 檔尾
// extension 的註解——同檔案 extension 成員依 SE-0169 仍能存取 `private` 的 `@State` 屬性與
// 上面 struct 的 `private` 成員，計數卻是分開算的。
extension InviteFamilyView {
    // MARK: - 破壞性重新產生

    private var destructiveSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            Text("重新產生邀請碼")
                .appFont(.note, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("重新產生後，舊的邀請碼就不能再用了。已經拿到舊邀請碼的家人，要再跟你要一次新的。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
            Button {
                showsRegenerateConfirmation = true
            } label: {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "arrow.triangle.2.circlepath").appIconFrame(.medium)
                    Text("重新產生一組").appFont(.body, weight: .semibold)
                }
                .foregroundStyle(Color.lsDanger)
            }
            .disabled(familyStore.createInviteState.isSubmitting)
        }
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "exclamationmark.circle.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsDanger)
            Text(error.userFacingMessage)
                .appFont(.note)
                .foregroundStyle(Color.lsDanger)
        }
    }

    // MARK: - Helpers

    func generate() {
        Task { await familyStore.createInvite(role: selectedRole) }
    }

    /// R2 N1：查詢失敗態的重試——呼叫跟 `onAppear` 相同的方法，成功會把 `lookupInviteState`
    /// 蓋回 `.success` 並帶出結果（或沒有既有碼就落回 `.empty`），不需要另外呼叫 reset。
    func retryLookup() {
        Task { await familyStore.refreshLatestInvite() }
    }

    func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        showsCopiedFeedback = true
        // R1 F10：先取消前一次還在等待的回饋 Task，兩秒內連按兩次才不會讓第一次的 Task
        // 到期把第二次剛設回 true 的 `showsCopiedFeedback` 提前清掉。
        copiedFeedbackTask?.cancel()
        copiedFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showsCopiedFeedback = false
        }
    }

    func inviteURL(_ code: String) -> URL {
        URL(string: "littlesprout://invite/\(code)") ?? URL(string: "littlesprout://invite")!
    }

    /// 6 碼邀請碼（LS-90：`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`，32 字元表）3+3 分組顯示；
    /// `prefix`/`suffix` 對任何長度都安全，不假設剛好 6 碼才不會在資料異常時整段崩潰。
    private func codeFirstHalf(_ code: String) -> String {
        String(code.prefix(3))
    }

    private func codeSecondHalf(_ code: String) -> String {
        String(code.suffix(max(0, code.count - 3)))
    }

    private func formattedCode(_ code: String) -> String {
        "\(codeFirstHalf(code))\u{2002}\(codeSecondHalf(code))"
    }

    private func formattedExpiry(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }
}

#if DEBUG
#Preview("空") {
    NavigationStack {
        InviteFamilyView(familyStore: .preview())
    }
}
#endif
