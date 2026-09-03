import SwiftUI

/// LS-18 / 04 首次進入三岔路（含 04-iPad）：已登入但還沒有家庭的使用者，選擇「我有邀請碼」
/// （整張卡可點，導去輸入邀請碼——06／06d，見 `JoinCodeView`／`JoinWaitingView`，LS-108）或
/// 「我要自己建立家庭」（05，見 `CreateFamilyView`）。
///
/// 版式依 `design/littlesprout.pen` frame `RxXvq`（iPhone）／`RHhJ1`（iPad）：LS-46 R11
/// 進場條件①「04 三岔路：主次已反轉，含照片的主大卡整張可點；『我要自己建立家庭』是底部一條
/// 列」（LS-18 comment `31d6e4e1` 未列出，但 Handoff Notes「N LS-18 家庭」i0 段有記載）。
struct ForkView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore
    /// LS-108 deep link：`littlesprout://invite/<code>`（LS-39 已註冊 scheme）冷／熱啟動皆帶碼
    /// 進 06 並預填。`LittleSproutApp` 用 `.onOpenURL` 寫入這個 binding，這裡消費（讀到就清空，
    /// 避免同一個碼被重複導頁）。
    @Binding var pendingInviteCode: String?

    @State private var path: [FamilyOnboardingRoute] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack(path: $path) {
            ScrollableFillView {
                Group {
                    if horizontalSizeClass == .regular {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
            }
            .appBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FamilyOnboardingRoute.self) { route in
                switch route {
                case .createFamily:
                    CreateFamilyView(familyStore: familyStore)
                case .joinCode(let initialCode):
                    JoinCodeView(familyStore: familyStore, path: $path, initialCode: initialCode)
                case .joinWaiting(let requestID, let familyID, let familyName, let submittedAt):
                    JoinWaitingView(
                        familyStore: familyStore,
                        path: $path,
                        requestID: requestID,
                        familyID: familyID,
                        familyName: familyName,
                        submittedAt: submittedAt
                    )
                }
            }
        }
        // deep link 熱啟動／冷啟動皆走這支：id 綁 `pendingInviteCode`，值一改變就重跑，初次掛載
        // 時目前值（含 App 冷啟動時已經先設好的碼）也會跑一次。
        .task(id: pendingInviteCode) {
            guard let code = pendingInviteCode else { return }
            pendingInviteCode = nil
            path = [.joinCode(initialCode: code)]
        }
        // 沒有 deep link 時的一次性「有沒有已經送出、還在等待的申請」檢查（例如加入申請送出後
        // 把 app 切到背景、過一陣子回來重新整個啟動——`ForkView` 是全新建立的，`path` 從空陣列
        // 重來，沒有這支會讓使用者看到空的三岔路，不知道自己其實已經申請過）。只在初次掛載跑
        // 一次（沒有 id），不依賴 `pendingInviteCode` 的變動。
        .task {
            guard path.isEmpty, pendingInviteCode == nil else { return }
            await navigateToJoinFlowIfPending()
        }
    }

    /// 三岔路「我有邀請碼」卡片的共用導頁邏輯：先確認有沒有已經送出、還在等待核准的申請
    /// （例如撤回失敗後重試、或從 06d「知道了，等通知」回到三岔路又點回來）——有就直接回到
    /// 06d，不要讓使用者誤以為自己得重新輸入一次碼；沒有才進 06。
    private func navigateToJoinFlow() async {
        if let existing = await familyStore.refreshMyJoinRequest(), existing.status == .pending {
            path = [.joinWaiting(
                requestID: existing.requestID,
                familyID: existing.familyID,
                familyName: existing.familyName,
                submittedAt: existing.createdAt
            )]
        } else {
            path.append(.joinCode(initialCode: ""))
        }
    }

    private func navigateToJoinFlowIfPending() async {
        guard let existing = await familyStore.refreshMyJoinRequest(), existing.status == .pending else { return }
        path = [.joinWaiting(
            requestID: existing.requestID,
            familyID: existing.familyID,
            familyName: existing.familyName,
            submittedAt: existing.createdAt
        )]
    }

    /// 沒有 `profiles.display_name` 可讀（LS-107 現況：登入流程目前不寫 `profiles`，見
    /// `SupabaseFamilyAPIClient.ensureProfileExists` 註解），用 email 本地部分頂替，比完全
    /// 不打招呼更貼近設計稿「歡迎，{name}」的意圖，且不是憑空捏造——就是使用者自己的帳號。
    private var greetingName: String {
        EmailDisplayName.derive(fromEmail: authStore.session?.email) ?? "你"
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            joinCard
                .padding(.top, AppSpacing.block)
            footerSection
                .padding(.top, AppSpacing.item)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
    }

    private var joinCard: some View {
        Button {
            Task { await navigateToJoinFlow() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                PrintPhotoCard(
                    photoHeight: 200,
                    cornerSize: 26,
                    mountPoolOpacity: .fork,
                    showsImprint: false,
                    imageName: "JoinParents",
                    accessibilityLabel: "家人在客廳裡團聚的合照"
                )
                VStack(alignment: .leading, spacing: AppSpacing.group) {
                    Text("我有邀請碼")
                        .appFont(.lead, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                    Text("家人給你 6 位邀請碼（英文數字混合）或邀請連結時，用這個送出加入申請。")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .padding(AppSpacing.insetCard)
                joinActionBar
            }
            .background(Color.lsSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                    .strokeBorder(Color.lsBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var joinActionBar: some View {
        HStack(spacing: AppSpacing.label) {
            Text("輸入邀請碼")
                .appFont(.body, weight: .bold)
            Image(systemName: "arrow.right")
                .appIconFrame(.medium)
        }
        .foregroundStyle(Color.lsOnAccent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.controlPaddingCTA)
        .background(Color.lsAccent)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.group) {
            Rectangle()
                .fill(Color.lsBorder)
                .frame(height: 1)
            createFamilyRow
            Text("之後也可以再建立或加入其他家庭。")
                .appFont(.meta)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .padding(.bottom, AppSpacing.item)
    }

    private var createFamilyRow: some View {
        Button {
            path.append(.createFamily)
        } label: {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "house.fill")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextPrimary)
                Text("我要自己建立家庭")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .appIconFrame(.medium)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("歡迎，\(greetingName)")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("萌芽日記以「家庭」為單位。多數人是家人邀請進來的——先看看你有沒有邀請碼。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    // MARK: - Regular (iPad)

    private var regularLayout: some View {
        HStack(alignment: .center, spacing: AppSpacing.section) {
            PrintPhotoCard(
                photoHeight: 484,
                cornerSize: 40,
                mountPoolOpacity: .forkIPad,
                showsImprint: false,
                imageName: "JoinParents",
                accessibilityLabel: "家人在客廳裡團聚的合照"
            )
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                iPadJoinCard
                    .padding(.top, AppSpacing.section)
                footerSection
                    .padding(.top, AppSpacing.block)
            }
            .frame(width: 294)
        }
        .padding(.horizontal, AppSpacing.screenPadLarge)
        .padding(.vertical, AppSpacing.section)
    }

    private var iPadJoinCard: some View {
        Button {
            Task { await navigateToJoinFlow() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.group) {
                    Text("我有邀請碼")
                        .appFont(.lead, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                    Text("家人給你 6 位邀請碼（英文數字混合）或邀請連結時，用這個送出加入申請。")
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .padding(AppSpacing.block)
                joinActionBar
            }
            .background(Color.lsSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                    .strokeBorder(Color.lsBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("iPhone") {
    ForkView(authStore: .preview(), familyStore: .preview(), pendingInviteCode: .constant(nil))
}

#Preview("iPad") {
    ForkView(authStore: .preview(), familyStore: .preview(), pendingInviteCode: .constant(nil))
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("AX3") {
    ForkView(authStore: .preview(), familyStore: .preview(), pendingInviteCode: .constant(nil))
        .dynamicTypeSize(.accessibility3)
}
#endif
