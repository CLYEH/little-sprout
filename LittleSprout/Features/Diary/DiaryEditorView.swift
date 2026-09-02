import PhotosUI
import SwiftUI

/// LS-125 / 日記編輯器（`design/littlesprout.pen` `LS-21 / 12*` 系列，依 LS-119 R13 核可稿）。
/// 版式：標題「寫日記」→ 內文 Text Field → 照片佇列（`DiaryEditorView+Photos.swift`）→ 記錄
/// 日期／寶貝歸屬兩個欄位（`DiaryEditorView+Fields.swift`）→ 釘底 Action Bar（`safeAreaInset`，
/// 同 `InviteFamilyView` 的既有慣例）。
///
/// 目前唯一入口是 `TimelineView` 導覽列的暫時「+」鈕（時間軸正式的建立入口／FAB 是 LS-126
/// 範圍，見該檔文件註解）——本票只保證「編輯器本身」對照核可稿，不做時間軸／Tab Bar。
struct DiaryEditorView: View {
    // 不是 private：`+Photos.swift`／`+Fields.swift`／`+ActionBar.swift` 需要讀寫（同下方
    // `@State` 群的既有慣例說明）。
    @State var store: DiaryComposerStore
    let childrenStore: ChildrenStore

    // 不是 private：`+Photos.swift`／`+Fields.swift`／`+ActionBar.swift` 是同一個型別的
    // extension，需要讀取（同上方 `@State` 群的既有慣例說明）。
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    // 不是 private：`DiaryEditorView+Photos.swift`／`+Fields.swift` 是同一個型別的 extension，
    // 需要讀寫這幾顆狀態（同 `InviteFamilyView`／`InviteFamilyView+Role.swift` 的既有慣例，見
    // 該檔文件註解）。
    @State var showsDatePicker = false
    @State var showsAttributionSheet = false
    @State var showsPhotosPicker = false
    @State var pickerSelection: [PhotosPickerItem] = []
    @State var draggingPhotoID: UUID?
    @State var dragTranslationX: CGFloat = 0

    init(
        familyID: UUID, diaryAPIClient: DiaryAPIClient, mediaUploadService: MediaUploadService,
        childrenStore: ChildrenStore
    ) {
        _store = State(initialValue: DiaryComposerStore(
            familyID: familyID, diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService
        ))
        self.childrenStore = childrenStore
    }

    var body: some View {
        @Bindable var store = store
        ScrollableFillView {
            Group {
                if horizontalSizeClass == .regular {
                    regularLayout
                } else {
                    compactLayout
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsDatePicker) {
            DiaryDatePickerSheet(selection: $store.entryDate)
        }
        .sheet(isPresented: $showsAttributionSheet) {
            AttributionSheet(childrenStore: childrenStore, selectedChildIDs: $store.selectedChildIDs)
        }
        .onChange(of: pickerSelection) { _, newItems in
            guard !newItems.isEmpty else { return }
            let itemsToLoad = newItems
            pickerSelection = []
            Task { await loadPicked(itemsToLoad) }
        }
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            cancelButton
            titleSection
                .padding(.top, AppSpacing.item)
            bodyTextField
                .padding(.top, AppSpacing.item)
            photosSection
                .padding(.top, AppSpacing.item)
            dateFieldSection
                .padding(.top, AppSpacing.section)
            childFieldSection
                .padding(.top, AppSpacing.item)
        }
        .padding(.horizontal, AppSpacing.screenPad)
        .padding(.bottom, AppSpacing.item)
    }

    // MARK: - Regular (iPad)

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            cancelButton
            regularColumns
        }
        .padding(.horizontal, AppSpacing.screenPadLarge)
        .padding(.top, AppSpacing.item)
        .padding(.bottom, AppSpacing.item)
    }

    private var regularColumns: some View {
        HStack(alignment: .top, spacing: AppSpacing.section) {
            VStack(alignment: .leading, spacing: 0) {
                titleSection
                bodyTextField
                    .padding(.top, AppSpacing.item)
                    .frame(maxHeight: .infinity)
                photosSection
                    .padding(.top, AppSpacing.item)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                dateFieldSection
                childFieldSection
                    .padding(.top, AppSpacing.item)
                publishInfoCard
                    .padding(.top, AppSpacing.block)
            }
            .frame(width: 360)
        }
        .padding(.top, AppSpacing.item)
    }

    // MARK: - 標題／內文

    private var titleSection: some View {
        Text("寫日記")
            .appFont(.display, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
    }

    private var bodyTextField: some View {
        @Bindable var store = store
        return TextEditor(text: $store.body)
            .appFont(.body)
            .foregroundStyle(Color.lsTextPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 116)
            .padding(AppSpacing.label)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
            )
            .disabled(store.publishState.isInFlight)
    }

    private var publishInfoCard: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "sparkles")
                .appIconFrame(.medium)
                .foregroundStyle(Color.lsTextSecondary)
            Text("發佈後，這篇日記會出現在全家人的時間軸上，大家都能看到、留言。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .padding(AppSpacing.insetCard)
        .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
    }

    // MARK: - Nav Back（`design/littlesprout.pen` `W6qTyS`，本畫面覆寫成「取消」）

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                Text("取消").appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsTextPrimary)
            // R1（模擬器實測抓到）：工具列自訂 Button 不會像系統預設返回鈕那樣自動撐出 44pt
            // 熱區——`frame(minHeight:)` 在 ToolbarItem 內對量測結果沒有效果（nav bar 用自己的
            // intrinsic content size 決定 bar button 高度，忽略內層 frame 的 minHeight）。改用
            // padding 直接加高內容本身（同 CreateChildView「之後再說」鈕／`SettingsView` 登出鈕
            // 的既有修法：`AppSpacing.controlPaddingMedium` 15.5pt 上下＋約 20pt 文字高＝
            // 51pt，實測足夠）。
            .padding(.vertical, AppSpacing.controlPaddingMedium)
            .contentShape(Rectangle())
        }
    }

    var fieldBackground: Color {
        store.publishState.isInFlight ? Color.lsSurface2 : Color.lsSurface
    }
}

/// 「記錄日期」欄位的系統日期選擇器——同 `BirthdayPickerSheet` 的既有慣例（`.sheet` +
/// wheel `DatePicker`），這裡的日期不設上限也不設下限：日記可以補寫任何一天，不像生日只能
/// 選過去。
struct DiaryDatePickerSheet: View {
    @Binding var selection: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            Text("選擇日期").appFont(.lead, weight: .bold).foregroundStyle(Color.lsTextPrimary)
            DatePicker("記錄日期", selection: $selection, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
            // R1（模擬器實測抓到，兩層教訓）：① `ToolbarItem(placement: .confirmationAction)`
            // 同 `cancelButton` 的既有教訓——nav bar bar button item 熱區不受內層
            // padding/frame 影響。② 改成一般 body content 後，`Button("完成") { }.frame(...)`
            // 這種「字串初始化＋外掛 frame/padding」寫法熱區依然鎖死在文字天然大小（量到只有
            // 33×20pt）——`.frame`／`.padding` 加在 Button 外層只改版面佔位，不會反向撐大
            // 按鈕本身的 hit-test 形狀。改用 `Button { } label: { }` 把 padding/background
            // 都做在 label 內部、label 收工後再 `.contentShape(Rectangle())` 明確鎖定熱區
            // （同 `cancelButton`／`removeSelectedButton` 的修法），實測才真的撐到 44pt+。
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .appFont(.body, weight: .bold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingCTA)
                    .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                            .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
        }
        .padding(AppSpacing.screenPad)
        .presentationDetents([.medium])
    }
}

#Preview("空白") {
    NavigationStack {
        DiaryEditorView(
            familyID: UUID(), diaryAPIClient: PreviewDiaryAPIClient(),
            mediaUploadService: PreviewMediaUploadService(), childrenStore: .preview()
        )
    }
}
