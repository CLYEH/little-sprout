import PhotosUI
import SwiftUI
import UIKit

/// LS-152 / 02 顯示名稱與頭像編輯（`design/littlesprout.pen` `MohS1`，依 LS-152 稿實作）：
/// 頭像沖印卡（方形縮圖，重用 LS-169 上傳基礎設施，見 `ChildAvatarUploadService
/// .uploadProfileAvatar` 文件註解）＋顯示名稱欄（1~50 字，對齊 `profiles
/// .profiles_display_name_check`）＋「儲存變更」主鈕。版式沿用 `EditChildView`（09b）的
/// 元件與提交流程慣例——同一套「頭像欄＋文字欄＋主鈕」骨架，這裡沒有生日欄與刪除動作。
///
/// 儲存後即時更新：`displayName`／頭像都直接寫回 `FamilyStore.myProfile`，設定頁「個人」列
/// （`ProfileSummaryRow`）讀的是同一份狀態，下一次重繪自然顯示新值，不需要額外的回呼或
/// 通知機制（見 `FamilyStore.updateDisplayName`／`updateAvatar` 文件註解）。「時間軸署名」
/// ——目前 `TimelineView`／日記卡沒有顯示作者姓名或頭像的 UI（`list_comments` RPC 雖然回傳
/// `author_display_name`／`author_avatar_url`，但留言功能還沒有對應畫面），沒有可更新的
/// 對象，記入 handoff「未完成」。
struct ProfileEditView: View {
    let familyStore: FamilyStore
    /// 上傳新頭像需要的家庭 id（Storage 路徑形狀 `{family_id}/avatars/{uuid}.jpg`）——理論上
    /// 一定有值：`SettingsView` 只在 `familyStore.myFamily != nil` 的已登入主畫面才進得去（見
    /// `RootView.AuthenticatedGate` 文件註解），這裡仍用 optional＋`submit()` 內的 guard，不
    /// force-unwrap，同 `FamilyStore.createInvite` 對「理論上不會、仍防禦性 guard」的既有慣例。
    let familyID: UUID?

    @State private var displayName = ""
    @State private var showsEmptyNameMessage = false
    @State private var pickedAvatarItem: PhotosPickerItem?
    @State private var pickedAvatarData: Data?
    @State private var pickedAvatarPreview: UIImage?
    @State private var isLoadingAvatar = false
    @State private var avatarLoadErrorMessage: String?
    // 世代守門，理由同 `EditChildView.avatarLoadCoordinator` 文件註解。
    @State private var avatarLoadCoordinator = AvatarLoadCoordinator()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                avatarField
                    .padding(.top, AppSpacing.section)
                nameField
                    .padding(.top, AppSpacing.item)
                Spacer(minLength: AppSpacing.item)
                footer
                    .padding(.bottom, AppSpacing.item)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.item)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            familyStore.resetUpdateDisplayNameState()
            familyStore.resetUpdateAvatarState()
            await familyStore.refreshProfile()
            if let name = familyStore.myProfile?.displayName {
                displayName = name
            }
        }
        .task(id: pickedAvatarItem) {
            await loadPickedAvatar()
        }
    }

    private var isSubmitting: Bool {
        familyStore.updateDisplayNameState.isSubmitting || familyStore.updateAvatarState.isSubmitting
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("顯示名稱與頭像")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("家人在家庭成員列表會看到這個名字和照片。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var avatarField: some View {
        VStack(spacing: AppSpacing.label) {
            PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
                ProfileAvatarEditCard(
                    name: displayName,
                    avatarURL: familyStore.avatarDisplayURL(rawValue: familyStore.myProfile?.avatarURL),
                    pickedImage: pickedAvatarPreview
                )
                .overlay { avatarLoadingOverlay }
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            if let avatarLoadErrorMessage {
                Text(avatarLoadErrorMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            if case .failure(let error) = familyStore.updateAvatarState {
                Text(error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 同 `EditChildView.avatarLoadingOverlay` 文件註解。
    @ViewBuilder
    private var avatarLoadingOverlay: some View {
        if isLoadingAvatar {
            Color.black.opacity(0.25)
            ProgressView().tint(.white)
        }
    }

    private var nameField: some View {
        LabeledTextField(
            label: "顯示名稱",
            placeholder: "陳美玲",
            text: Binding(
                get: { displayName },
                set: { newValue in
                    displayName = newValue
                    showsEmptyNameMessage = false
                }
            ),
            helpText: nameHelpText,
            isError: isNameError,
            submitLabel: .done
        )
        .disabled(isSubmitting)
    }

    private var nameHelpText: String {
        if isSubmitting { return "送出期間先不能修改。" }
        if showsEmptyNameMessage { return "還沒填名字。在上面打上名字，再按一次。" }
        if case .failure(let error) = familyStore.updateDisplayNameState { return error.userFacingMessage }
        return "家人在家庭成員列表會看到這個名字。"
    }

    private var isNameError: Bool {
        guard !isSubmitting, !showsEmptyNameMessage else { return false }
        if case .failure = familyStore.updateDisplayNameState { return true }
        return false
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            PrimaryButton(
                icon: "checkmark",
                title: "儲存變更",
                isLoading: isSubmitting,
                loadingTitle: "正在儲存…",
                action: submit
            )
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
            }
            .disabled(isSubmitting)
        }
    }

    /// PUT 語意整組送出（同 `EditChildView.submit()` 既有慣例）：顯示名稱一定送；有選新照片
    /// 才接著上傳＋寫入，沒選就不動 `avatar_url`。任一步失敗都停在原地顯示對應錯誤，不
    /// `dismiss()`。
    private func submit() {
        guard !isSubmitting else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showsEmptyNameMessage = true
            return
        }
        Task {
            guard await familyStore.updateDisplayName(trimmed) else { return }
            if let pickedAvatarData {
                guard let familyID else {
                    // 理論上不會發生，見本型別 `familyID` 屬性文件註解——fail loud，不靜默丟棄
                    // 使用者已經選好的照片。
                    avatarLoadErrorMessage = "沒有家庭可以上傳頭像，請重新整理後再試一次。"
                    return
                }
                guard await familyStore.updateAvatar(familyID: familyID, imageData: pickedAvatarData) else { return }
            }
            dismiss()
        }
    }

    /// 同 `EditChildView.loadPickedAvatar()` 文件註解。
    private func loadPickedAvatar() async {
        guard let pickedAvatarItem else { return }
        isLoadingAvatar = true
        avatarLoadErrorMessage = nil
        let result = await avatarLoadCoordinator.load {
            try await AvatarPickerLoader.load(pickedAvatarItem)
        }
        if result.isCurrent {
            isLoadingAvatar = false
        }
        switch result.outcome {
        case .applied(let data, let previewImage):
            pickedAvatarData = data
            pickedAvatarPreview = previewImage
        case .discarded:
            break
        case .failed(let message):
            pickedAvatarData = nil
            pickedAvatarPreview = nil
            avatarLoadErrorMessage = message
        }
    }
}

/// 02 頭像欄內容——沖印卡方形縮圖（`PhotoCornerOverlay` 四角托，同 `AvatarPrintCard` 的既有
/// 母題）＋相機 Edit Badge（同 `EditChildAvatarFieldContent` 的既有慣例）。跟兩者都不完全
/// 相同，另建一份：`AvatarPrintCard`（建檔，無既有照片，永遠是空白占位）與
/// `EditChildAvatarFieldContent`（編輯，但圓形頭像）都不是這裡要的「編輯態＋方形」組合，
/// 同檔案既有慣例是每個畫面各自一份小型元件，不跨畫面共用（見 `EditChildAvatarFieldContent`
/// 文件註解）。
private struct ProfileAvatarEditCard: View {
    let name: String
    var avatarURL: URL?
    var pickedImage: UIImage?

    private let cardSize: CGFloat = 140
    private let cornerSize: CGFloat = 26

    /// LS-67 R3 F24 同款四角染料池——見 `AvatarPrintCard` 文件註解，這裡沿用同一組示意透明度
    /// （這個元件跟 `AvatarPrintCard` 一樣是「沖印卡」母題的另一個實例，透明度數字沒有理由
    /// 重新調過）。
    private static let mountPoolOpacity = PrintPhotoCard.MountPoolOpacity(
        topLeading: 0.429, topTrailing: 0.275, bottomLeading: 0.367, bottomTrailing: 0.245
    )

    var body: some View {
        VStack(spacing: AppSpacing.label) {
            ZStack(alignment: .bottomTrailing) {
                photoCard
                editBadge
            }
            Text("換張照片")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("我的頭像，點一下可以換照片")
    }

    private var photoCard: some View {
        photoWrap
            .frame(width: cardSize, height: cardSize)
            .clipped()
            .padding(AppSpacing.printEdge)
            .background(mountPoolGlow.clipped())
            .background(Color.lsPrintPaper)
            .overlay(PhotoCornerOverlay(size: cornerSize))
    }

    @ViewBuilder
    private var photoWrap: some View {
        if let pickedImage {
            Image(uiImage: pickedImage).resizable().scaledToFill()
        } else if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialsPlaceholder
                }
            }
        } else {
            initialsPlaceholder
        }
    }

    private var initialsPlaceholder: some View {
        ZStack {
            Color.lsSurface2
            Text(ChildAvatarInitial.initial(for: name))
                .font(.system(size: cardSize * 0.35, weight: .bold))
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var editBadge: some View {
        Circle()
            .fill(Color.lsSurface)
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(Color.lsControlLine, lineWidth: 1.5))
            .overlay(
                Image(systemName: "camera")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsTextPrimary)
            )
            .offset(x: 4, y: 4)
    }

    private var mountPoolGlow: some View {
        GeometryReader { proxy in
            let diameter = cornerSize * 6
            ZStack {
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topLeading)
                    .position(x: 0, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.topTrailing)
                    .position(x: proxy.size.width, y: 0)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomLeading)
                    .position(x: 0, y: proxy.size.height)
                glow(diameter: diameter, opacity: Self.mountPoolOpacity.bottomTrailing)
                    .position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }

    private func glow(diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.lsMountPool.opacity(opacity), Color.lsMountPoolFade],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ProfileEditView(familyStore: .preview(withFamily: Family(
            id: UUID(), name: "陳家", createdBy: UUID(), createdAt: Date(), requireApproval: true
        )), familyID: UUID())
    }
}
#endif
