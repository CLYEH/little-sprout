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
        childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
    ))
}

#Preview("04h 失敗") {
    DeletionFailedView(model: DeleteAccountFlowModel(
        accountAPIClient: PreviewAccountAPIClient(), familyStore: .preview(), authStore: .preview(),
        childrenStore: .preview(), timelineStore: .preview(), albumsStore: .preview()
    ))
}
#endif
