import SwiftUI

/// LS-18 / 04 首次進入三岔路（含 04-iPad）：已登入但還沒有家庭的使用者，選擇「我有邀請碼」
/// （整張卡可點，導去輸入邀請碼——06 由 LS-108 實作，這裡先接一個標記清楚的佔位畫面）或
/// 「我要自己建立家庭」（05，見 `CreateFamilyView`）。
///
/// 版式依 `design/littlesprout.pen` frame `RxXvq`（iPhone）／`RHhJ1`（iPad）：LS-46 R11
/// 進場條件①「04 三岔路：主次已反轉，含照片的主大卡整張可點；『我要自己建立家庭』是底部一條
/// 列」（LS-18 comment `31d6e4e1` 未列出，但 Handoff Notes「N LS-18 家庭」i0 段有記載）。
struct ForkView: View {
    let authStore: AuthStore
    let familyStore: FamilyStore

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
                case .joinPlaceholder:
                    JoinFamilyPlaceholderView()
                }
            }
        }
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
            path.append(.joinPlaceholder)
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
            path.append(.joinPlaceholder)
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

#Preview("iPhone") {
    ForkView(authStore: .preview(), familyStore: .preview())
}

#Preview("iPad") {
    ForkView(authStore: .preview(), familyStore: .preview())
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("AX3") {
    ForkView(authStore: .preview(), familyStore: .preview())
        .dynamicTypeSize(.accessibility3)
}
