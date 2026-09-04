import PhotosUI
import SwiftUI
import UIKit

/// LS-113 / 08（＋08-iPad）幫寶貝建立檔案。版式依 `design/littlesprout.pen` frame `P27HS`
/// （iPhone）／`J8TvbH`（iPad）：頭像欄（沖印品母題，印相罩＋角托＋壓印行即時姓名預覽）＋
/// 姓名欄（沿用既有 `LabeledTextField`）＋生日欄（自建 tappable row＋系統日期選擇器）＋
/// 「建立寶貝檔案」主鈕＋「之後再說」文字鈕。
///
/// 兩個呼叫情境共用同一個畫面（LS-67 設計註記：「新增寶貝沿用 08 空表單，不重複出稿」）：
/// ① 建立家庭後的 onboarding 接續（`RootView` 用 `.fullScreenCover(isPresented:
///   $familyStore.showsChildOnboarding)` 呈現，`dismiss()` 會自動把那個 binding 寫回
///   `false`，不需要額外的完成回呼）；② 09 管理畫面「新增寶貝」`NavigationLink` 推入的一般
///   新增流程（`dismiss()` 在推入的情境下改成 pop）——兩種情境下「建立成功」與「之後再說」
///   都只是呼叫同一個環境 `dismiss()`，呼叫端不需要額外傳完成回呼進來。
///
/// LS-169：頭像欄改成真的可點——`PhotosPicker`（單選、只圖片）選出的項目交給
/// `AvatarPickerLoader.load`（背景降採樣出預覽圖，見該檔文件註解）讀成
/// `pickedAvatarData`（完整原始位元組，上傳前給 `AvatarImageProcessor` 裁方用）＋
/// `pickedAvatarPreview`（降採樣後的預覽圖，`body` 直接讀這個 `@State`，不再自己解碼）；
/// `submit()` 成功後把 `pickedAvatarData` 交給 `childrenStore.createChild` 處理裁方＋
/// 上傳＋`update_child`。
///
/// R2 M3：`.task(id: pickedAvatarItem)` 取代原本 `.onChange` + 裸 `Task`——`id` 改變（連續
/// 選兩張）時 SwiftUI 自動取消前一個 task、畫面消失時也自動取消，不需要自己保存／取消
/// `Task` 參照；載入失敗（`AvatarPickerLoader.LoadError`）會落 `avatarLoadErrorMessage`
/// 顯示出來，不是原本 `try?` 靜默吞掉、預覽悄悄退回佔位。
struct CreateChildView: View {
    let childrenStore: ChildrenStore

    // 非 private：`CreateChildView+Avatar.swift` 的 `avatarField` 要讀（見下方那批
    // @State 的同一則檔頭註解）。
    @State var name = ""
    @State private var birthday: Date?
    @State private var showsEmptyNameMessage = false
    @State private var showsEmptyBirthdayMessage = false
    @State private var showsDatePicker = false
    // R2：頭像欄的狀態與載入邏輯（`avatarField`／`avatarLoadingOverlay`／
    // `loadPickedAvatar()`）拆去 `CreateChildView+Avatar.swift`（SwiftLint
    // `type_body_length` 逼出來的搬移，理由同 `MediaUploadService+Duration.swift`
    // 檔頭註解）——`private` 是以檔案為界，搬到別的檔案就存取不到，這裡改用預設
    // （internal）存取層級，範圍仍只在本 module 內。
    @State var pickedAvatarItem: PhotosPickerItem?
    @State var pickedAvatarData: Data?
    @State var pickedAvatarPreview: UIImage?
    @State var isLoadingAvatar = false
    @State var avatarLoadErrorMessage: String?
    // R3 n2：世代計數器——`.task(id:)` 取消舊 task 後，舊 task 的 defer／catch 仍會繼續
    // 執行到底，若不比對世代會寫壞新 task 已經設定的 isLoadingAvatar／錯誤文案／預覽圖
    // （見 `loadPickedAvatar()` 文件註解）。
    @State var avatarLoadGeneration = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    private static let defaultBirthday = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

    var body: some View {
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
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDatePicker) {
            BirthdayPickerSheet(selection: birthdayBinding)
        }
        .onAppear { childrenStore.resetCreateState() }
        .task(id: pickedAvatarItem) {
            await loadPickedAvatar()
        }
    }

    var isSubmitting: Bool { childrenStore.createState.isSubmitting }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
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

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("幫寶貝建立檔案")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("填好基本資料，就能開始記錄他的成長了。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
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
        return "家人在時間軸上會看到這個名字。"
    }

    private var isNameError: Bool {
        !isSubmitting && showsEmptyNameMessage
    }

    private var birthdayField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("生日")
                .appFont(.body, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            birthdayBox
            HStack(alignment: .top, spacing: AppSpacing.label) {
                Image(systemName: isBirthdayError ? "exclamationmark.circle.fill" : "info")
                    .appIconFrame(.small)
                    .foregroundStyle(isBirthdayError ? Color.lsDanger : Color.lsTextSecondary)
                Text(birthdayHelpText)
                    .appFont(.note)
                    .fontWeight(isBirthdayError ? .semibold : .regular)
                    .foregroundStyle(isBirthdayError ? Color.lsDanger : Color.lsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var birthdayBox: some View {
        Button {
            showsDatePicker = true
        } label: {
            HStack {
                HStack(spacing: AppSpacing.label) {
                    Image(systemName: "calendar")
                        .appIconFrame(.medium)
                        .foregroundStyle(Color.lsTextSecondary)
                    Text(birthdayValueText)
                        .appFont(.body)
                        .foregroundStyle(birthday == nil ? Color.lsTextSecondary : Color.lsTextPrimary)
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
                    .strokeBorder(
                        isBirthdayError ? Color.lsDanger : Color.lsControlLine,
                        lineWidth: isBirthdayError ? 2 : 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private var birthdayValueText: String {
        guard let birthday else { return "選擇生日" }
        return BirthdayFormat.displayString(from: birthday)
    }

    private var birthdayHelpText: String {
        if isSubmitting { return "送出期間先不能修改。" }
        if showsEmptyBirthdayMessage { return "還沒選生日。點上面的欄位選一個日期，再按一次。" }
        if case .failure(let error) = childrenStore.createState { return error.userFacingMessage }
        return "之後可以再修改，家人加入後才看得到。"
    }

    private var isBirthdayError: Bool {
        guard !isSubmitting, !showsEmptyBirthdayMessage else { return false }
        if case .failure = childrenStore.createState { return true }
        return false
    }

    private var birthdayBinding: Binding<Date> {
        Binding(
            get: { birthday ?? Self.defaultBirthday },
            set: { newValue in
                birthday = newValue
                showsEmptyBirthdayMessage = false
            }
        )
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.group) {
            PrimaryButton(
                icon: "checkmark",
                title: "建立寶貝檔案",
                isLoading: isSubmitting,
                loadingTitle: "正在建立…",
                action: submit
            )
            Button(action: skip) {
                Text("之後再說")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    // R1（模擬器實測抓到）：稿面 `cmp/Button Text` 的 `$ctl-pad-tap`（9.5）
                    // 量出來只有 39pt 高，低於 44pt 下限（同 SettingsView 登出鈕 LS-17 QA1
                    // 的先例：改用較大的內距撐大點擊區，視覺仍是純文字、不加框）。
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
            }
            .disabled(isSubmitting)
        }
    }

    // MARK: - Regular (iPad)

    private var regularLayout: some View {
        HStack(alignment: .center, spacing: AppSpacing.section) {
            VStack(spacing: AppSpacing.label) {
                PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
                    AvatarPrintCard(name: name, photoHeight: 504, cornerSize: 40, pickedImage: pickedAvatarPreview)
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
            .frame(width: 420)
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    nameField
                    birthdayField
                }
                .padding(.top, AppSpacing.section)
                footer
                    .padding(.top, AppSpacing.section)
            }
            .frame(width: 294)
        }
        .padding(.horizontal, AppSpacing.screenPadLarge)
        .padding(.top, AppSpacing.screenPadLarge)
    }

    // MARK: - Actions

    private func submit() {
        guard !isSubmitting else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var hasError = false
        if trimmedName.isEmpty {
            showsEmptyNameMessage = true
            hasError = true
        }
        if birthday == nil {
            showsEmptyBirthdayMessage = true
            hasError = true
        }
        guard !hasError, let birthday else { return }
        Task {
            if await childrenStore.createChild(
                name: trimmedName, birthday: birthday, avatarImageData: pickedAvatarData
            ) {
                dismiss()
            }
        }
    }

    private func skip() {
        guard !isSubmitting else { return }
        dismiss()
    }
}

/// 生日的系統日期選擇器——稿面只表達觸發點與已選值的排版（`design/littlesprout.pen` `N
/// 建檔（08）` 註記），實際容器由 ios-dev 決定，這裡用 `.sheet`＋wheel `DatePicker`。
/// `EditChildView`（09b）共用同一個元件，因此不是 `private`。
struct BirthdayPickerSheet: View {
    @Binding var selection: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("生日", selection: $selection, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(AppSpacing.screenPad)
                .navigationTitle("選擇生日")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

#if DEBUG
#Preview("空白") {
    NavigationStack {
        CreateChildView(childrenStore: .preview())
    }
}

#Preview("iPad") {
    NavigationStack {
        CreateChildView(childrenStore: .preview())
    }
    .environment(\.horizontalSizeClass, .regular)
}
#endif
