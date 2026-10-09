import PhotosUI
import SwiftUI

/// 03 第一次記錄 sheet／03b 編輯記錄 sheet／03e 儲存失敗（LS-380，`design/littlesprout.pen` `FP2An`〔iPhone〕／
/// `TRLN6`〔深色〕／`qV7XY`〔AX3〕；03b `ekxHM`＋`K6MMar`；03e `NgnYl`＋`Yufqp`）。第一次記錄與編輯共用同一支
/// 畫面（Notes「編輯同 sheet」），差別只在表頭（灰色空位／紙片＋標題）、照片欄初值與編輯才有的「刪除這筆記錄」。
///
/// 畫面級屬性（Notes `jyt14` 03／03b／03e 三列，逐條落地）：
/// - 隱藏 Tab Bar ✗（sheet 呈現，本身沒有 Tab Bar 可隱藏）。
/// - 標題自訂：左側 Food Slot（還沒吃＝灰色空位、編輯＝紙片）＋`$fs-lead` 靠左（`header`），不用系統 nav bar。
/// - 釘底動作帶：無——Footer（Status Slot＋儲存／取消）隨 sheet 捲動（Notes `hqrit`「sheet Footer 不釘底，
///   隨 sheet 捲動（沿 LS-252 Growth/02）」）。
/// - 失敗文案鍵 42501／LS044／LS051／LS052／LS053／23514／`food.save_failed`：Status Slot 同一格顯示
///   （`FoodRecordCopy.saveFailed`），儲存鈕不位移（見 `statusSlot`）。
/// - 深色：token 自動（紙不反轉由 `print-paper` token 保證），不另寫分支。
/// - AX3（`dynamicTypeSize.isAccessibilitySize`）：表頭直排、照片兩顆鈕直排、反應三選項直排、日期明確斷兩行、
///   備註框不設固定高；Status Slot 仍是 max() 規則，**不寫死 348**（Notes `hqrit`／池 d5bf5b56）。
/// - iPad：同一 sheet（系統 form sheet 寬度），不另排版。
/// - 資料落點：`first_tried_on`／`media_id`／`reaction`／`note` 經 `upsert_child_food_record`；刪除經
///   `delete_child_food_record`（03c，`FoodRecordSheet+Actions.swift`）。
///
/// **Grabber 自畫**，同 `GrowthMeasurementFormView`／`DeleteConfirmationSheet` 既有理由（系統
/// `.presentationDragIndicator` 會被 tap-target gate 誤判成 <44pt 違規）。
struct FoodRecordSheet: View {
    let childName: String
    let apiClient: FoodAPIClient
    /// 儲存成功（sheet 關閉之前）——呼叫端把回傳列套進圖鑑，並安排「收下」動效（06）。
    var onSaved: (ChildFoodRecord) -> Void
    /// 刪除成功（確認 sheet 與本 sheet 都關閉之前）——呼叫端把那一格退回「還沒吃」。
    var onDeleted: (UUID) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var store: FoodRecordEditorStore
    @State var showsDatePicker = false
    @State var showsFamilyPicker = false
    @State var showsPhoneSourceChoice = false
    @State var showsPhonePicker = false
    @State var phoneSelection: PhotosPickerItem?
    @State var showsDeleteConfirmation = false
    /// 03c 刪除成功後，等確認 sheet 自己關完（`onDismiss`）再關本 sheet——同一個 runloop 內連關兩層會被
    /// 系統吞掉其中一個 dismiss。
    @State var closesAfterDeleteConfirmation = false
    @State var photoURLs: [String: URL] = [:]

    init(
        childName: String, store: FoodRecordEditorStore, apiClient: FoodAPIClient,
        onSaved: @escaping (ChildFoodRecord) -> Void, onDeleted: @escaping (UUID) -> Void = { _ in }
    ) {
        self.childName = childName
        self.apiClient = apiClient
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _store = State(initialValue: store)
    }

    var isAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                header
                VStack(alignment: .leading, spacing: AppSpacing.block) {
                    dateField
                    photoField
                    reactionField
                    noteField
                }
                footer
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.section)
        }
        .background(Color.lsSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(store.saveState.isSubmitting)
        .sheet(isPresented: $showsDatePicker) {
            FoodRecordDatePickerSheet(selection: $store.firstTriedOn)
        }
        .sheet(isPresented: $showsFamilyPicker) { familyPicker }
        .confirmationDialog("換一張照片", isPresented: $showsPhoneSourceChoice, titleVisibility: .visible) {
            Button("從家庭相簿挑") { showsFamilyPicker = true }
            Button("從手機加入") { showsPhonePicker = true }
        }
        .photosPicker(isPresented: $showsPhonePicker, selection: $phoneSelection, matching: .images)
        .onChange(of: phoneSelection) { loadPhonePhoto() }
        .sheet(isPresented: $showsDeleteConfirmation, onDismiss: closeAfterDeleteIfNeeded) { deleteConfirmation }
        .task { await store.loadExistingPhoto() }
        .task(id: store.photo) { await signSelectedFamilyPhotoIfNeeded() }
    }

    // MARK: - 表頭

    private var header: some View {
        VStack(spacing: AppSpacing.group) {
            Capsule()
                .fill(Color.lsBorder)
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            let slot = FoodSlot(foodID: store.item.id, isTried: store.isEditing)
            let text = VStack(alignment: .leading, spacing: AppSpacing.tight) {
                Text(FoodRecordCopy.headTitle(
                    childName: childName, foodName: store.item.nameZh, isEditing: store.isEditing
                ))
                .appFont(.lead, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
                .accessibilityAddTraits(.isHeader)
                Text(store.item.category.displayName)
                    .appFont(.note)
                    .foregroundStyle(Color.lsTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isAccessibilityLayout {
                VStack(alignment: .leading, spacing: AppSpacing.item) { slot; text }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: AppSpacing.item) { slot; text }
            }
        }
        .padding(.top, AppSpacing.block)
    }

    // MARK: - Footer（Status Slot＋動作，隨 sheet 捲動）

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            statusSlot
            VStack(spacing: AppSpacing.group) {
                PrimaryButton(title: "儲存", isLoading: store.saveState.isSubmitting, loadingTitle: "正在儲存…") {
                    submit()
                }
                .accessibilityIdentifier("foodRecord.save")
                textButton(title: "取消", icon: nil, color: .lsTextPrimary, action: cancel)
            }
            if store.isEditing {
                textButton(title: "刪除這筆記錄", icon: "trash", color: .lsDanger) {
                    guard !store.saveState.isSubmitting else { return }
                    showsDeleteConfirmation = true
                }
                // 03c 確認 sheet 的確認鈕同字（「刪除這筆記錄」）——這顆給 identifier，UITest 才分得出兩顆。
                .accessibilityIdentifier("foodRecord.delete")
            }
        }
    }

    /// Status Slot（Notes `hqrit`，池 d5bf5b56）：高度＝一般句與失敗句中較高者，**在目前字級下即時量**——
    /// `ZStack` 疊全部候選句，非當前那句 `opacity(0)`＋`accessibilityHidden`，ZStack 自然取最高者的高度；
    /// 不寫死任何 frame 高度（稿面 56／348 只是 Pencil 實測值）。候選句恆含 03e 稿面那句失敗句，所以第一次
    /// 失敗時 Slot 不長高、儲存鈕不位移（`FoodRecordSheetUITests.testFailureKeepsSaveButtonInPlace`）。
    private var statusSlot: some View {
        let current = currentStatus
        let candidates = FoodRecordStatus.candidates(
            current: current, foodName: store.item.nameZh, isEditing: store.isEditing
        )
        return ZStack(alignment: .topLeading) {
            ForEach(candidates, id: \.self) { status in
                statusRow(status, isCurrent: status == current)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("foodRecord.statusSlot")
    }

    private var currentStatus: FoodRecordStatus {
        if case .failure(let error) = store.saveState {
            return .failure(FoodRecordCopy.saveFailed(error))
        }
        if store.photoLoadFailed { return .failure(FoodRecordCopy.photoUnsupported) }
        return .normal(FoodRecordCopy.statusNormal(foodName: store.item.nameZh, isEditing: store.isEditing))
    }

    /// 非當前那句 `opacity(0)`＋`accessibilityHidden`（VoiceOver 只唸看得到的那句）；identifier 也分開——XCUITest
    /// 的元素樹不理會 `accessibilityHidden`，當前句要能被唯一查到。
    private func statusRow(_ status: FoodRecordStatus, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.tight) {
            Image(systemName: status.isFailure ? "exclamationmark.circle" : "info.circle").appIconFrame(.small)
            Text(status.text)
                .appFont(.note, weight: status.isFailure ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(status.isFailure ? Color.lsDanger : Color.lsTextSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isCurrent ? "foodRecord.statusText" : "foodRecord.statusText.reserved")
        .opacity(isCurrent ? 1 : 0)
        .accessibilityHidden(!isCurrent)
    }

    /// cmp/Button Text（`qe9yS`）：無框文字鈕，`minHeight 48`（≥44pt 再加緩衝，同 `DeleteConfirmationSheet`）。
    func textButton(title: String, icon: String?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.label) {
                if let icon { Image(systemName: icon).appIconFrame(.medium) }
                Text(title).appFont(.body, weight: .semibold)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - 動作

    private func submit() {
        guard !store.saveState.isSubmitting else { return }
        Task {
            guard let saved = await store.save() else { return }
            onSaved(saved)
            dismiss()
        }
    }

    private func cancel() {
        guard !store.saveState.isSubmitting else { return }
        dismiss()
    }
}

/// Status Slot 的一句：一般（`$text-secondary`、info 圖示）／失敗（`$danger`、circle-alert、semibold）。
enum FoodRecordStatus: Hashable {
    case normal(String)
    case failure(String)

    var text: String {
        switch self {
        case .normal(let text), .failure(let text): text
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    /// Status Slot 疊在一起量高度的候選句（Notes `hqrit` max() 規則）：一般句＋03e 稿面失敗句（恆在，
    /// 保證第一次失敗時不長高），當前句若是別的失敗句（其餘錯誤碼／照片讀不出來）也疊進來。去重、順序固定。
    static func candidates(current: FoodRecordStatus, foodName: String, isEditing: Bool) -> [FoodRecordStatus] {
        var result: [FoodRecordStatus] = [
            .normal(FoodRecordCopy.statusNormal(foodName: foodName, isEditing: isEditing)),
            .failure(FoodRecordCopy.saveFailedNetwork)
        ]
        if !result.contains(current) { result.append(current) }
        return result
    }
}

/// 表頭左側的 Food Slot（稿 `I6Mq1c`／03b `TdD2n`：cmp/Food Cell 實例寬 104、Text Stack 關閉）——還沒吃＝
/// 透明底＋髮絲框＋灰階貼紙；編輯＝紙片＋彩色貼紙。
struct FoodSlot: View {
    let foodID: String
    let isTried: Bool

    private static let side: CGFloat = 104
    private static let stickerSize: CGFloat = 80

    var body: some View {
        FoodStickerImage(foodID: foodID, size: Self.stickerSize, isGrayscale: !isTried)
            .frame(width: Self.side, height: Self.side)
            .background { FoodCellBackground(state: isTried ? .tried(firstTriedOn: Date()) : .untried) }
            .accessibilityHidden(true)
    }
}
