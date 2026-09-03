import SwiftUI

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
/// 大頭貼上傳／裁切不在本票範圍（LS-67 設計註記 E3：本稿頭像一律用姓名縮寫圓圈，若需要
/// 真的能選照片，需另開任務）——這裡的相機圖示是視覺佔位，刻意不掛任何互動，避免看起來
/// 能點卻毫無反應的「假按鈕」。
struct CreateChildView: View {
    let childrenStore: ChildrenStore

    @State private var name = ""
    @State private var birthday: Date?
    @State private var showsEmptyNameMessage = false
    @State private var showsEmptyBirthdayMessage = false
    @State private var showsDatePicker = false
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
    }

    private var isSubmitting: Bool { childrenStore.createState.isSubmitting }

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

    private var avatarField: some View {
        AvatarPrintCard(name: name)
            .frame(maxWidth: .infinity)
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
            AvatarPrintCard(name: name, photoHeight: 504, cornerSize: 40)
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
            if await childrenStore.createChild(name: trimmedName, birthday: birthday) {
                dismiss()
            }
        }
    }

    private func skip() {
        guard !isSubmitting else { return }
        dismiss()
    }
}

/// 頭像欄的沖印品母題（`design/littlesprout.pen` `z4C4f`/`wrX2m`）：印相罩＋角托＋壓印行，
/// 但相片區塊放的是「新增照片」佔位（相機圖示＋文字，見本檔文件註解的 E3 範圍說明），壓印行
/// 顯示即時姓名預覽（空欄位時退回單一空白，撐住行高，同 `CreateFamilyView.FamilyPreviewCard`
/// 的 `content:" "` 慣例）。與 `PrintPhotoCard` 結構相同但相片內容／壓印文字皆不同，未重用
/// 該元件（`PrintPhotoCard` 壓印行固定印 "LITTLE SPROUT"，唯一出現地是歡迎頁家族，見
/// `little-sprout-brand` skill 進場條件④）——這裡另建一份小型、僅本畫面使用的版本。
private struct AvatarPrintCard: View {
    let name: String
    var photoHeight: CGFloat = 88
    var cornerSize: CGFloat = 26

    /// LS-67 R3 F24：08/08c 染料池四角 opacity（TL.429 TR.275 BL.367 BR.245）。
    private static let mountPoolOpacity = PrintPhotoCard.MountPoolOpacity(
        topLeading: 0.429, topTrailing: 0.275, bottomLeading: 0.367, bottomTrailing: 0.245
    )

    var body: some View {
        VStack(spacing: 7) {
            photoWrap
            imprintRow
        }
        .padding(.top, AppSpacing.printEdge)
        .padding(.horizontal, AppSpacing.printEdge)
        .padding(.bottom, AppSpacing.printEdgeBottom)
        .background(mountPoolGlow.clipped())
        .background(Color.lsPrintPaper)
        .overlay(PhotoCornerOverlay(size: cornerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("新增寶貝照片，目前尚未選擇")
    }

    private var photoWrap: some View {
        VStack(spacing: AppSpacing.label) {
            Image(systemName: "camera")
                .appIconFrame(.large)
                .foregroundStyle(Color.lsTextSecondary)
            Text("點這裡新增照片")
                .appFont(.note, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: photoHeight)
        .background(Color.lsSurface2)
    }

    private var imprintRow: some View {
        Text(displayName)
            .appFont(.lead, weight: .semibold)
            .foregroundStyle(Color.lsPrintInk)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? " " : trimmed
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
