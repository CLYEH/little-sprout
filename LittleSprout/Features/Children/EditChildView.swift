import PhotosUI
import SwiftUI
import UIKit

/// LS-113 / 09b 編輯寶貝資料。版式依 `design/littlesprout.pen` frame `BqxHJ`：大頭貼預覽
/// （縮寫圓／照片＋相機 Edit Badge，LS-169 起真的能點換照片——見 `CreateChildView` 文件註解）＋
/// 姓名欄／生日欄（與 08 同一套元件，預填既有值）＋「儲存變更」主鈕＋「取消」文字鈕。
///
/// 「移除這個寶貝」（僅 owner）：LS-67 R2 設計註記（`UhhwS` I1）原意是把移除動作收斂到本畫面
/// 底部，但 R3／R4 修版後實際 09b（compact）frame 只剩 Save／Cancel 兩顆按鈕——09-iPad
/// （`JbTfv`）的右欄編輯面板則確實畫了「移除這個寶貝」文字鈕。09c（移除確認 sheet）是完整
/// 設計好的畫面，必須有入口能觸發；沒有這顆鈕，iPhone 上將完全沒有刪除孩子檔案的路徑，
/// 也無法滿足票文驗收條件「建檔→列表→編輯→軟刪→還原全流程在模擬器可完成」。這裡依 iPad
/// 已有的設計語彙（trash icon＋danger 色文字鈕）把它加回 compact 版本，放在 Cancel 之後
/// （比照 `InviteFamilyView` 破壞性動作放在畫面下段、與主要動作分開的既有慣例）——記於
/// handoff 風險欄，供 merge-reviewer／QA 複核這個落差判斷。
struct EditChildView: View {
    let childrenStore: ChildrenStore
    let child: Child

    @State private var name: String
    @State private var birthday: Date
    @State private var showsEmptyNameMessage = false
    @State private var showsDatePicker = false
    @State private var showsDeleteConfirmation = false
    @State private var pickedAvatarItem: PhotosPickerItem?
    @State private var pickedAvatarData: Data?
    @State private var pickedAvatarPreview: UIImage?
    @State private var isLoadingAvatar = false
    @State private var avatarLoadErrorMessage: String?
    // R3 n2：世代計數器，理由同 `CreateChildView.avatarLoadGeneration` 文件註解——擋掉被
    // 取消的舊 task 在 `defer`／`catch` 裡蓋掉新 task 已寫入的載入狀態。
    @State private var avatarLoadGeneration = 0
    @Environment(\.dismiss) private var dismiss

    init(childrenStore: ChildrenStore, child: Child) {
        self.childrenStore = childrenStore
        self.child = child
        _name = State(initialValue: child.name)
        _birthday = State(initialValue: child.birthday)
    }

    var body: some View {
        ScrollableFillView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                avatarField
                    .padding(.top, AppSpacing.section)
                nameField
                    .padding(.top, AppSpacing.item)
                birthdayField
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
        .onAppear { childrenStore.resetUpdateState() }
        .sheet(isPresented: $showsDatePicker) {
            BirthdayPickerSheet(selection: $birthday)
        }
        .sheet(isPresented: $showsDeleteConfirmation) {
            DeleteChildSheet(childrenStore: childrenStore, child: child) {
                showsDeleteConfirmation = false
                dismiss()
            }
        }
        .task(id: pickedAvatarItem) {
            await loadPickedAvatar()
        }
    }

    private var isSubmitting: Bool { childrenStore.updateState.isSubmitting }

    /// R2 M2/M3：同 `CreateChildView.loadPickedAvatar` 文件註解——`.task(id:)` 自動取消
    /// 前一次選取的載入，載入失敗會落 `avatarLoadErrorMessage` 顯示出來，不是靜默吞掉。
    ///
    /// R3 n2：世代守門，理由同 `CreateChildView+Avatar.swift` 的 `loadPickedAvatar()` 文件
    /// 註解——被取消的舊 task 仍會跑到 `defer`／`catch` 才結束，寫任何狀態前先確認自己仍是
    /// 最新世代；`CancellationError` 一律靜默，不需要世代判斷。
    private func loadPickedAvatar() async {
        guard let pickedAvatarItem else { return }
        avatarLoadGeneration += 1
        let generation = avatarLoadGeneration
        isLoadingAvatar = true
        avatarLoadErrorMessage = nil
        defer {
            if generation == avatarLoadGeneration {
                isLoadingAvatar = false
            }
        }
        do {
            let loaded = try await AvatarPickerLoader.load(pickedAvatarItem)
            guard generation == avatarLoadGeneration else { return }
            pickedAvatarData = loaded.data
            pickedAvatarPreview = loaded.previewImage
        } catch is CancellationError {
            // 被下一次選取取消，狀態交給後面那個 task 寫（一律靜默）。
        } catch {
            guard generation == avatarLoadGeneration else { return }
            pickedAvatarData = nil
            pickedAvatarPreview = nil
            avatarLoadErrorMessage = "這張照片沒辦法使用，請換一張試試。"
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("編輯寶貝資料")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("\(child.name)的基本資料，家人和你都能修改。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
    }

    private var avatarField: some View {
        VStack(spacing: AppSpacing.label) {
            PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
                // LS-169：內容抽成獨立的 `EditChildAvatarFieldContent`（`View`-conforming
                // struct），不是像 `avatarField` 本身這樣直接把 `appFont`／`appIconFrame`
                // 呼叫寫在 `PhotosPicker` 的 label 尾隨閉包裡——實測（Swift 6 嚴格並行檢查）
                // `PhotosPicker` 的 `label` 閉包參數不繼承外層 `EditChildView`（`View`
                // 協定推導出的）`@MainActor` 隔離，直接在閉包本體呼叫這兩個 `@MainActor`
                // 隔離的自訂 View extension 方法會編譯失敗（"non-Sendable 'some View'-typed
                // result can not be returned from main actor-isolated instance method ...
                // to nonisolated context"）。獨立 View struct 的 `body` 本身就是
                // `@MainActor`（`View`協定要求），閉包只需要呼叫它的 initializer（非隔離、
                // 純建構值），交給 SwiftUI 之後才真正求值 `body`——同 `CreateChildView` 的
                // `AvatarPrintCard` 抽出方式一致。
                EditChildAvatarFieldContent(
                    name: name, avatarURL: childrenStore.avatarURL(for: child), pickedImage: pickedAvatarPreview
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
        }
    }

    /// 同 `CreateChildView.avatarLoadingOverlay` 文件註解。
    @ViewBuilder
    private var avatarLoadingOverlay: some View {
        if isLoadingAvatar {
            Circle().fill(Color.black.opacity(0.25))
            ProgressView().tint(.white)
        }
    }

    private var nameField: some View {
        LabeledTextField(
            label: "姓名或暱稱",
            placeholder: "陳小安",
            text: Binding(
                get: { name },
                set: { newValue in
                    name = newValue
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
        if case .failure(let error) = childrenStore.updateState { return error.userFacingMessage }
        return "家人在時間軸上會看到這個名字。"
    }

    private var isNameError: Bool {
        guard !isSubmitting, !showsEmptyNameMessage else { return false }
        if case .failure = childrenStore.updateState { return true }
        return false
    }

    private var birthdayField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("生日")
                .appFont(.body, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Button {
                showsDatePicker = true
            } label: {
                HStack {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "calendar")
                            .appIconFrame(.medium)
                            .foregroundStyle(Color.lsTextSecondary)
                        Text(BirthdayFormat.displayString(from: birthday))
                            .appFont(.body)
                            .foregroundStyle(Color.lsTextPrimary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsTextSecondary)
                }
                .padding(.horizontal, AppSpacing.insetCard)
                .frame(minHeight: 60)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Image(systemName: "info")
                    .appIconFrame(.small)
                    .foregroundStyle(Color.lsTextSecondary)
                Text("只有家人看得到完整生日，其他人只看得到年齡。")
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    // R1（模擬器實測抓到）：`$ctl-pad-tap` 量出來只有 39pt 高，低於 44pt
                    // 下限，同 `CreateChildView` 之後再說鈕的理由。
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
            }
            .disabled(isSubmitting)
            if childrenStore.isOwner {
                Divider().background(Color.lsBorder)
                Button {
                    showsDeleteConfirmation = true
                } label: {
                    HStack(spacing: AppSpacing.label) {
                        Image(systemName: "trash").appIconFrame(.small)
                        Text("移除這個寶貝").appFont(.body, weight: .semibold)
                    }
                    .foregroundStyle(Color.lsDanger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
                }
                .disabled(isSubmitting)
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showsEmptyNameMessage = true
            return
        }
        Task {
            let success = await childrenStore.updateChild(
                childID: child.id, name: trimmed, birthday: birthday,
                currentAvatarURL: child.avatarURL, newAvatarImageData: pickedAvatarData
            )
            if success { dismiss() }
        }
    }
}

/// LS-113 / 09c 移除寶貝確認（僅 owner）。版式依 `design/littlesprout.pen` frame
/// `iq3Ic`：bottom sheet（grabber＋標題＋完整文案交代 30 天可還原＋照片日記保留）＋外框
/// danger 確認鈕（不是實心——danger 不做主鍵）＋取消文字鈕。用 `.sheet`＋
/// `.presentationDetents` 自訂樣式（稿面文件註記允許：「容器彈性由實作決定」）。
private struct DeleteChildSheet: View {
    let childrenStore: ChildrenStore
    let child: Child
    /// 軟刪成功後呼叫——關掉這張 sheet，並讓呼叫端（`EditChildView`）一併退回列表。
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Capsule().fill(Color.lsBorder).frame(width: 36, height: 5)
            Text("要移除\(child.name)的檔案嗎？")
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .multilineTextAlignment(.center)
            Text(
                "移除後，\(child.name)不會再出現在寶貝清單裡。照片和日記都會留著，不會刪掉。" +
                "30 天內你隨時可以把他還原回來；過了 30 天，就不能再還原了。"
            )
            .appFont(.note)
            .foregroundStyle(Color.lsTextPrimary)
            if case .failure(let error) = childrenStore.deleteState {
                Text(error.userFacingMessage)
                    .appFont(.note, weight: .semibold)
                    .foregroundStyle(Color.lsDanger)
            }
            VStack(spacing: AppSpacing.group) {
                Button(action: confirmDelete) {
                    HStack(spacing: AppSpacing.label) {
                        if childrenStore.deleteState.isSubmitting {
                            ProgressView()
                        } else {
                            Image(systemName: "trash").appIconFrame(.medium)
                        }
                        Text(childrenStore.deleteState.isSubmitting ? "正在移除…" : "移除，30 天內可還原")
                            .appFont(.body, weight: .bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
                }
                .foregroundStyle(Color.lsDanger)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsDanger, lineWidth: 1.5)
                )
                .disabled(childrenStore.deleteState.isSubmitting)
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .appFont(.body, weight: .semibold)
                        .foregroundStyle(Color.lsTextPrimary)
                        .frame(maxWidth: .infinity)
                        // R1（模擬器實測抓到）：同上，`$ctl-pad-tap` 撐不到 44pt。
                        .padding(.vertical, AppSpacing.controlPaddingMedium)
                }
                .disabled(childrenStore.deleteState.isSubmitting)
            }
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.top, AppSpacing.block)
        .padding(.bottom, AppSpacing.section)
        .presentationDetents([.medium])
        .onAppear { childrenStore.resetDeleteState() }
    }

    private func confirmDelete() {
        guard !childrenStore.deleteState.isSubmitting else { return }
        Task {
            if await childrenStore.setChildDeleted(childID: child.id, deleted: true) {
                onDeleted()
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        EditChildView(
            childrenStore: .preview(),
            child: Child(
                id: UUID(), name: "陳小安", birthday: Date(),
                avatarURL: nil, deletedAt: nil, createdAt: Date()
            )
        )
    }
}
#endif
