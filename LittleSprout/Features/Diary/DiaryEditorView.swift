import PhotosUI
import SwiftUI

/// LS-125 / 日記編輯器（`design/littlesprout.pen` `LS-21 / 12*` 系列，依 LS-119 R13 核可稿）。
/// 版式：標題「寫日記」→ 內文 Text Field → 照片佇列（`DiaryEditorView+Photos.swift`）→ 記錄
/// 日期／寶貝歸屬兩個欄位（`DiaryEditorView+Fields.swift`）→ 釘底 Action Bar（`safeAreaInset`，
/// 同 `InviteFamilyView` 的既有慣例）。
///
/// 入口是 `TimelineView` Header 停靠的具名建立鈕「＋ 新增回憶」（LS-126 依 LS-119 核可稿落地，
/// 取代了本票原本導覽列的暫時「+」鈕，已整顆移除，見該檔文件註解）——本票只保證「編輯器
/// 本身」對照核可稿，不做時間軸／Tab Bar。
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

    #if DEBUG
    /// LS-212 R3（merge-review R2 `695170ed`）：測試專用注入點——`DiaryEditorViewLifecycleTests`
    /// 需要在呼叫 `publish()`（讓 `store.uploadedMediaByDraftID` 先有孤兒 media）之後才把同一個
    /// `store` 交給 view host，才驗證得到 `.onDisappear` 觸發 `discardDraft()` 這條 defense-in-
    /// depth 路徑（見 `body` 的 `.onDisappear` 文件註解）——這是可測性需求，不是因為生產路徑上
    /// 有哪個入口會漏接清理（R1 `568044ab` 曾誤判「互動式滑走會漏接」，R2 `695170ed` 已實測
    /// 訂正，見同一個 modifier 的文件註解）。一般生產路徑（`TimelineView`／
    /// `TapTargetGateHarness`）沒有這個需求，繼續用上面那支建構子；同
    /// `UploadQueueStore.PreviewSeed`／`seedForPreview` 只給 `#Preview`／測試用的既有慣例。
    init(store: DiaryComposerStore, childrenStore: ChildrenStore) {
        _store = State(initialValue: store)
        self.childrenStore = childrenStore
    }
    #endif

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
        // QA 視覺對稿 FAIL（LS-125 comment `ed017e85`）：稿面 canvas 高度預算完全沒有 Tab
        // Bar（Status Bar+Nav+Body+Action Bar+Home Indicator=906），但這裡只隱藏了
        // navigation bar，推入這個畫面時 App 的 Tab Bar 仍在 Action Bar 下方完整顯示。
        .toolbar(.hidden, for: .tabBar)
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
        // LS-212 R3（merge-review R2 `695170ed` 訂正 R1 `568044ab` 的誤判）：R1 曾誤判「互動式
        // 返回手勢（邊緣滑走）依然有效、會繞過 cancelButton」，本輪重新實測（真正的
        // DiaryEditorView，四種滑動手勢逐一操作＋正向對照組）證實
        // `.navigationBarBackButtonHidden(true)`＋`.toolbar(.hidden, for: .navigationBar)` 這支
        // 畫面上**確實關掉了**互動式返回手勢（與 UIKit「隱藏 navigation bar 會連帶停用
        // interactivePopGestureRecognizer」的既有行為一致）——`cancelButton`（連同發佈成功後的
        // 自動 dismiss）本來就是這支畫面目前唯一的離開路徑，不會漏接。
        //
        // 仍然掛在這裡而不是只掛在 `cancelButton` 的理由是 **defense in depth**：「沒有互動式
        // 滑走手勢」這件事繫於上面那兩個 modifier，未來若有人動了它們、或新增了其他能讓這支
        // 畫面消失的路徑（例如祖先鏈 `AuthenticatedRootView` 的
        // `.fullScreenCover(isPresented: familyStore.showsChildOnboarding)`——目前流程下不可能
        // 與開著的編輯器同時出現，但這正是這道防線設計要接住的那種未來情境），掛在
        // `.onDisappear` 的清理不會跟著默默失效，掛在單一按鈕上會。`discardDraft()` 本身的
        // `guard publishState != .success` 會擋住「發佈成功後 dismiss」這條路徑，不會誤刪已經
        // 合法 attach 的 media（見該方法文件註解）；已用計數器實測「記錄日期」／「寶貝歸屬」
        // `.sheet` 與 `.photosPicker` 開關皆不誤觸發。`Task` 持有 `store` 的強參照，view 消失後
        // 這支 Task 仍會跑完，不受 View 生命週期影響（同 `UploadQueueStore` 檔頭既有慣例）；不
        // `await` 是因為清理是背景衛生工作，不該讓 `.onDisappear` 阻塞畫面轉場。
        .onDisappear {
            Task { await store.discardDraft() }
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

    /// R5 對稿（`design/littlesprout.pen` `b3PELj`）：右欄固定寬度原本是截圖比例估算的
    /// `360`，量到的實際值是 `294`；左右欄之間的 `HStack` gap 量到 `$screen-pad-lg`（40），
    /// 不是 `$sp-section`（44）；右欄內部（日期→寶貝→提示卡）三個區塊之間的間距量到全部是
    /// `$sp-section`（44），不是原本各自沿用的 `.item`／`.block`。
    private var regularColumns: some View {
        HStack(alignment: .top, spacing: AppSpacing.screenPadLarge) {
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
                    .padding(.top, AppSpacing.section)
                publishInfoCard
                    .padding(.top, AppSpacing.section)
            }
            .frame(width: 294)
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
        return VStack(alignment: .leading, spacing: AppSpacing.label) {
            TextEditor(text: $store.body)
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
                .accessibilityIdentifier(QAAccessibilityID.diaryBodyEditor)
            // merge-review R1 M1／m10：空內文不是「發佈失敗」，不借用 Action Bar 的失敗態
            // （那裡的文案「你寫的內容還在，可以直接重試」對「根本還沒送出過」語意矛盾）——
            // 就地顯示在內文欄位旁，跟其他表單的「還沒做完」提示同一套視覺。
            if store.showsEmptyBodyMessage {
                replyRow(text: "日記還沒寫內容，加幾個字再發佈吧。")
            }
        }
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
            // LS-212 R3（merge-review R2 `695170ed` 訂正 R1 `568044ab` 的誤判）：清理已經改掛
            // 在 `body` 的 `.onDisappear`（見該 modifier 文件註解）——這裡只需要觸發
            // dismiss，不必另外呼叫 `store.discardDraft()`。R1 曾誤判這支畫面的互動式返回
            // 手勢（邊緣滑走）仍然有效、會繞過這顆按鈕；R2 實測（真正的 DiaryEditorView，四種
            // 滑動手勢皆推不掉，正向對照組確認手法有效）證實
            // `.navigationBarBackButtonHidden(true)`＋`.toolbar(.hidden, for: .navigationBar)`
            // 確實關掉了互動式返回手勢，這顆按鈕本來就是唯一離開路徑，不會漏接。改掛
            // `.onDisappear` 純粹是 defense in depth，理由見該 modifier 文件註解。
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
        // merge-review R1 m1：發佈中如果還能取消，畫面會直接 dismiss，但上傳／
        // `create_diary_entry` 沒有被中止，日記照樣送出——其餘控制項在 in-flight 時都有這條
        // `.disabled`，這裡原本漏掛。
        .disabled(store.publishState.isInFlight)
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

#if DEBUG
#Preview("空白") {
    NavigationStack {
        DiaryEditorView(
            familyID: UUID(), diaryAPIClient: PreviewDiaryAPIClient(),
            mediaUploadService: PreviewMediaUploadService(), childrenStore: .preview()
        )
    }
}
#endif
