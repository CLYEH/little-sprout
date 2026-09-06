import SwiftUI

/// 04f 進行中／04g 完成／04h 失敗（`design/littlesprout.pen` `vrqoe`／`ZilRp`／`soWA9`）：
/// LS-193——見 `DeleteAccountFlowView.swift` 檔頭對整組畫面拆檔理由的說明。三板皆置中版式、
/// 無系統導覽列（`DeleteAccountStep.showsNavigationBar`），共用 `StatusBadgeIcon`。

/// 88×88 外圈徽章＋40×40 icon（LS-152 Notes「Status Badge」段的尺寸族——`AppIconToken` 沒有
/// 40 這一檔，這裡就地用 `@ScaledMetric` 對齊 Dynamic Type 縮放慣例，不是硬寫死 pt）。
private struct StatusBadgeIcon: View {
    let backgroundColor: Color
    let iconColor: Color
    /// `nil`＝顯示 `ProgressView()`（04f：lucide `loader-circle` 依 SF Symbol 對照表指示換成
    /// 真正的系統轉圈，不用靜態 icon）。
    let systemImage: String?

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

    var body: some View {
        Circle()
            .fill(backgroundColor)
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize))
                        .foregroundStyle(iconColor)
                } else {
                    ProgressView().tint(iconColor)
                }
            }
    }
}

private struct StatusTextBlock: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: AppSpacing.label) {
            Text(title)
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text(note)
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - 三分流防禦態（merge-review R1 M1，無對應設計稿）

/// `DeleteAccountClassification.pending`——`familyStore.members` 尚未載回時顯示，取代 R1 版
/// 直接代打 `.generalMember` 的錯誤行為（見 `DeleteAccountStep.swift` 文件註解）。沒有對應
/// 設計稿：比照 `RootView+AuthenticatedGate.swift` 的 `FamilyLookupFailedView` 既有先例，這是
/// 純技術性防禦畫面，不套用沖印品母題。「繼續刪除帳號」鈕沿用 04a 的 `DeleteAccountDangerButton`
/// 但 `.disabled(true)`——分流結果還沒確定之前不能讓使用者往下走到 04e（`.pending` 這個狀態
/// 一旦解出來，`content` 會自動換到 04a／04b／04d 之一，不需要這裡的鈕真的能按）。
struct DeleteAccountMembersPendingView: View {
    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Spacer()
            ProgressView()
            Text("正在確認你的家庭狀態…")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            DeleteAccountDangerButton(icon: "arrow.right", label: "繼續刪除帳號", action: {})
                .disabled(true)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.block)
    }
}

/// `DeleteAccountClassification.membersLoadFailed`——`familyStore.membersState == .failure`
/// 時顯示。沒有對應設計稿：沿用 04h（`soWA9`）的 `StatusBadgeIcon`／`StatusTextBlock`／
/// `DeleteAccountAccentButton`「重試」語彙，不是重新設計一張新畫面。「重試」呼叫
/// `familyStore.refreshMembers()`（重新查成員清單），不是 `model.confirmDeletion()`
/// （04h 的重試是重打 RPC／Edge Function）——視覺語彙相同、語意不同。
struct DeleteAccountMembersLoadFailedView: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Spacer()
            StatusBadgeIcon(
                backgroundColor: Color.lsSurface2, iconColor: Color.lsDanger,
                systemImage: "exclamationmark.circle.fill"
            )
            StatusTextBlock(title: "無法確認你的家庭狀態", note: error.userFacingMessage)
            Spacer()
            DeleteAccountAccentButton(icon: "arrow.counterclockwise", label: "重試", action: retry)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.block)
    }
}

// MARK: - 04f 進行中（`vrqoe`）

struct DeletionInProgressView: View {
    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Spacer()
            StatusBadgeIcon(backgroundColor: Color.lsSurface2, iconColor: Color.lsTextSecondary, systemImage: nil)
            StatusTextBlock(
                title: "正在刪除你的帳號…",
                note: "請不要關閉 App，這可能需要幾秒鐘。完成前請留在這個畫面。"
            )
            Spacer()
        }
        .padding(.horizontal, AppSpacing.screenPad)
    }
}

// MARK: - 04g 完成（`ZilRp`）

struct DeletionCompletedView: View {
    let model: DeleteAccountFlowModel

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Spacer()
            StatusBadgeIcon(backgroundColor: Color.lsSuccess, iconColor: Color.lsOnAccent, systemImage: "checkmark")
            StatusTextBlock(
                title: "帳號已刪除",
                note: "謝謝你使用過萌芽日記。你的帳號與個人資料已經刪除。"
            )
            Spacer()
            DeleteAccountAccentButton(
                icon: "arrow.right", label: "回到登入畫面", action: doneTapped, isLoading: model.isFinishing
            )
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.block)
    }

    private func doneTapped() {
        Task { await model.finishAndReturnToWelcome() }
    }
}

// MARK: - 04h 失敗（`soWA9`）

struct DeletionFailedView: View {
    let model: DeleteAccountFlowModel

    @State private var showsContactSheet = false

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Spacer()
            StatusBadgeIcon(
                backgroundColor: Color.lsSurface2, iconColor: Color.lsDanger,
                systemImage: "exclamationmark.circle.fill"
            )
            StatusTextBlock(
                title: "刪除過程中發生問題",
                note: "你的帳號可能還沒有完全刪除。請重新嘗試一次；如果一直失敗，可以聯絡我們協助處理。"
            )
            Spacer()
            VStack(spacing: AppSpacing.group) {
                DeleteAccountAccentButton(
                    icon: "arrow.counterclockwise", label: "重試", action: model.confirmDeletion,
                    isLoading: model.isProcessing
                )
                DeleteAccountTextButton(label: "聯絡我們", action: { showsContactSheet = true })
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.block)
        // 「聯絡我們」沒有真正的客服信箱可用（docs/legal/privacy-policy.md 目前仍是
        // `[[SUPPORT_EMAIL]]` 佔位，LS-132 文本核可前不存在真實值）——改開既有《隱私權政策》
        // sheet（§14「聯絡我們」一節），不是自己編一個假的信箱地址，見 handoff「未完成」段。
        .sheet(isPresented: $showsContactSheet) {
            LegalDocumentSheet(kind: .privacyPolicy)
        }
    }
}

#if DEBUG
#Preview("04f 進行中") {
    DeletionInProgressView()
}

#Preview("04g 完成") {
    DeletionCompletedView(model: DeleteAccountFlowModel(
        accountAPIClient: PreviewAccountAPIClient(), familyStore: .preview(), authStore: .preview(),
        childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
        eulaStore: .preview(shouldPresent: false), resumer: .preview()
    ))
}

#Preview("04h 失敗") {
    DeletionFailedView(model: DeleteAccountFlowModel(
        accountAPIClient: PreviewAccountAPIClient(), familyStore: .preview(), authStore: .preview(),
        childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview(),
        eulaStore: .preview(shouldPresent: false), resumer: .preview()
    ))
}
#endif
