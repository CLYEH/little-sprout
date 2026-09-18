import SwiftUI

/// 02 新增／編輯量測 sheet（LS-313，`design/littlesprout.pen` Notes `h5BNyi`→`KWEaE`〔base〕／
/// `qrFWJ`〔全空〕／`L9AvJN`〔超出範圍〕／`S4Pdz`〔深色〕；抄值段 `x7FXr`／`i9Rxq`）。取代
/// LS-312 的 `GrowthAddMeasurementPlaceholderView` 空殼——「新增量測」（`editingRecord ==
/// nil`）與「編輯」（非 nil，帶入既有值）共用同一支畫面，唯一差異是 Head Title 與是否已有
/// 初始值（Notes：「編輯既有筆＝同 sheet 帶入值」）。
///
/// 畫面級屬性（Notes `mfafV`→`zgN6U`，逐條落地）：隱藏 Tab Bar ✗（sheet 呈現，本身沒有 Tab
/// Bar 可隱藏）；標題自訂 Head Title（`.appFont(.lead, weight: .bold)`，見 `header`）；釘底
/// 動作帶＝Save／Cancel（`actions`，見 `body`），不是系統 `.toolbar`；失敗文案鍵 23514／
/// LS051／LS052／LS053（見 `statusText`，`AppError.map` 已把這幾碼映射進 `LSErrorCode`／
/// `42501`/`23514` 既有分流，這裡只需要把 `growthStore.saveState` 的 `.failure` 顯示出來，
/// 不需要另外對碼）；深色靠 token 全自動反轉，不另畫分支；AX3 特例 Range Warning Slot／
/// Status Slot 改 `fit_content`（見 `Self.slotHeight`）。
///
/// **Grabber 自畫**，同 `DeleteConfirmationSheet`／`ContentActionsSheet` 既有理由（LS-190
/// R2）：系統 `.presentationDragIndicator` 會被 `tap-target-check.sh` 誤判成 <44pt 違規。
///
/// **四態儲存鈕同座標**（Notes `GpxTB`／`hQpxd`：「四板 Actions 絕對 y 皆為 42750」）：只有
/// `actions`（Save／Cancel）釘在 `ScrollView` 外——R1 模擬器實測 AX3 下發現原本「兩個插槽
/// 固定 56pt、其餘也固定在 ScrollView 外」的寫法會讓外層 VStack 空間不足時反過來擠壓 Footer，
/// Status Slot 文字被截斷成「⋯」（`body` 文件註解細節）；改成日期／量測群組／備註／Status
/// Slot 全部收進同一個 ScrollView，只有 Actions 在外，Actions 的位置完全不受表單內容或字級
/// 影響，比原本更直接地保證「四態同座標」。
struct GrowthMeasurementFormView: View {
    let growthStore: GrowthStore
    /// nil＝新增；非 nil＝編輯這一筆（帶入既有值，`upsert_growth_record` 的 `p_id` 走這個
    /// `id`）。
    let editingRecord: GrowthRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredOn: Date
    @State private var heightText: String
    @State private var weightText: String
    @State private var headText: String
    @State private var note: String
    @State private var showsDatePicker = false
    /// 使用者按過一次「儲存」且當下三項全空——Status Slot 從中性提示（`$text-secondary`）
    /// 升級成回話式提醒（`$text-primary`，Notes B-4：「不再逐欄標紅…改為…回話列語彙」）。輸入
    /// 之後（任一項非空）或再次按下儲存都會清掉，不需要额外的「使用者是否碰過欄位」追蹤。
    @State private var showsEmptyMessage = false
    @State private var statusScrollRequest = 0

    init(growthStore: GrowthStore, editingRecord: GrowthRecord? = nil) {
        self.growthStore = growthStore
        self.editingRecord = editingRecord
        _measuredOn = State(initialValue: editingRecord.flatMap { Self.localMidnight(from: $0.measuredOn) } ?? Date())
        _heightText = State(initialValue: Self.text(for: editingRecord?.heightCm))
        _weightText = State(initialValue: Self.text(for: editingRecord?.weightKg))
        _headText = State(initialValue: Self.text(for: editingRecord?.headCm))
        _note = State(initialValue: editingRecord?.note ?? "")
    }

    /// 編輯既有筆回填——`%.1f` 沿用 `GrowthMetric.formattedValue` 逐字元相同的格式（該函式
    /// 三個 case 共用同一段實作，不依賴呼叫在哪個 case 上，這裡不特地挑一個 case 當代表）。
    private static func text(for value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? ""
    }

    /// R1 merge-review M1：`editingRecord.measuredOn` 是 UTC 午夜（`GrowthRecord` 解碼慣例，
    /// 同 `Child.birthday`），但 `measuredOn` 這個 `@State` 全程被 `dateFieldLabel`（裝置本地
    /// 時區的 `Calendar(identifier: .gregorian)`）與送出時的 `BirthdayFormat.wireString(from:
    /// calendar: .current)` 當成「裝置本地時區的 Date」在用。在負時區裝置（例如
    /// America/New_York）直接把 UTC 午夜塞進去，本地時區抽出的年月日會退回一天。這裡先把
    /// UTC 午夜的年月日抽出來，換成「裝置本地時區同一組年月日的午夜」，之後兩處用本地時區
    /// 抽出的年月日才會跟原始 `measuredOn` 一致（往返不變）。`calendar` 參數同 `BirthdayFormat.
    /// wireString(from:calendar:)` 既有理由——預設 `.current`，測試才能注入固定時區；不設
    /// `private`，`GrowthMeasurementFormViewTimeZoneTests` 需要直接呼叫這支純函式驗證。
    static func localMidnight(from utcDate: Date, calendar: Calendar = .current) -> Date? {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = utcCalendar.dateComponents([.year, .month, .day], from: utcDate)
        return calendar.date(from: components)
    }

    /// R1 merge-review m1：改用 `GrowthMeasurementValidation.parsedMeasurement(from:)`——原本
    /// 直接 `Double(text)` 不吃逗號小數點、沒有限一位小數、也沒有擋 0／超上限（見該函式文件
    /// 註解）。
    private var heightValue: Double? { GrowthMeasurementValidation.parsedMeasurement(from: heightText) }
    private var weightValue: Double? { GrowthMeasurementValidation.parsedMeasurement(from: weightText) }
    private var headValue: Double? { GrowthMeasurementValidation.parsedMeasurement(from: headText) }

    private var hasAtLeastOneValue: Bool {
        GrowthMeasurementValidation.hasAtLeastOneValue(heightCm: heightValue, weightKg: weightValue, headCm: headValue)
    }

    private var rangeWarning: String? {
        GrowthMeasurementValidation.rangeWarning(heightCm: heightValue, weightKg: weightValue, headCm: headValue)
    }

    /// Notes `x7FXr`／`i9Rxq`：一般字級兩個插槽固定 56pt；AX3 改 `fit_content`（讓長警語文字
    /// 完整換行，不裁切）。
    private var isAX3: Bool { dynamicTypeSize >= .accessibility3 }

    /// R1 模擬器實測抓到的真實 bug（AX3）：原本只有「日期欄＋量測群組」在 `ScrollView` 裡，
    /// Note Field／Status Slot／Actions 都在 ScrollView 外的固定 Footer——AX3 下三個量測欄＋
    /// 備註欄本身都長高很多，Footer 這個「固定」區塊反而被外層 VStack 擠壓到低於自己需要的
    /// 高度，Status Slot 的文字被逼著截斷成「⋯」。改成**只有 Actions（Save／Cancel）釘底**
    /// （Notes GpxTB「釘底動作帶」字面意思），其餘（日期／量測群組／備註／Status Slot）全部
    /// 收進同一個 `ScrollView`——這樣 Actions 的垂直位置只由自己的高度決定，完全不受
    /// 表單內容多寡／字級影響，比原本「兩個插槽各自固定高度」更直接地保證「四態儲存鈕同座標」
    /// （不管哪個插槽的文字多長，Actions 都在 ScrollView 之外、同一個位置）。
    var body: some View {
        VStack(spacing: 0) {
            grabber
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.section) {
                        header
                        dateField
                        measurementGroup
                        VStack(alignment: .leading, spacing: AppSpacing.item) {
                            noteField
                            statusSlot.id(Self.statusSlotID)
                        }
                    }
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.top, AppSpacing.item)
                }
                .clipped()
                .onChange(of: statusScrollRequest) {
                    withAnimation { proxy.scrollTo(Self.statusSlotID, anchor: .bottom) }
                }
            }
            actions
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.item)
                .padding(.bottom, AppSpacing.item)
        }
        .background(Color.lsSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showsDatePicker) {
            GrowthMeasurementDatePickerSheet(selection: $measuredOn)
        }
        .onAppear { growthStore.resetSaveState() }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private var header: some View {
        Text(editingRecord == nil ? "新增量測" : "編輯量測")
            .appFont(.lead, weight: .bold)
            .foregroundStyle(Color.lsTextPrimary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    // MARK: - 日期

    private var dateField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("測量日期")
                .appFont(.body, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Button {
                showsDatePicker = true
            } label: {
                HStack {
                    Text(dateFieldLabel)
                        .appFont(.body)
                        .foregroundStyle(Color.lsTextPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "calendar")
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
            .disabled(growthStore.saveState.isSubmitting)
        }
    }

    /// Notes `KWEaE`「8月20日（今天）」——同一天才加「（今天）」；不跨年一律省略年份（同
    /// `GrowthRecord.measuredOnHistoryLabel` 既有慣例，03／03b 兩處已經是這個形狀，這裡沿用
    /// 而不是另外發明一套帶年份的格式）。
    private var dateFieldLabel: String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.month, .day], from: measuredOn)
        let base = "\(components.month ?? 0)月\(components.day ?? 0)日"
        return calendar.isDateInToday(measuredOn) ? "\(base)（今天）" : base
    }

    // MARK: - 量測群組

    private var measurementGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.item) {
            LabeledTextField(
                label: "身高（cm）", placeholder: "請輸入身高", text: measurementBinding($heightText), helpText: nil,
                keyboardType: .decimalPad
            )
            .disabled(growthStore.saveState.isSubmitting)
            LabeledTextField(
                label: "體重（kg）", placeholder: "請輸入體重", text: measurementBinding($weightText), helpText: nil,
                keyboardType: .decimalPad
            )
            .disabled(growthStore.saveState.isSubmitting)
            LabeledTextField(
                label: "頭圍（cm）", placeholder: "請輸入頭圍", text: measurementBinding($headText), helpText: nil,
                keyboardType: .decimalPad
            )
            .disabled(growthStore.saveState.isSubmitting)
            rangeWarningSlot
        }
    }

    /// 同 `CreateChildView.nameField` 既有慣例：使用者開始打字（三個量測欄任何一個）就清掉
    /// `showsEmptyMessage`——R1 模擬器實測抓到的真實 bug：全空送出一次後 Status Slot 升級成
    /// 「請至少填寫…」，接著在身高欄打了 180，Range Warning Slot 正確跳出來，但 Status Slot
    /// 沒有跟著退回中性提示，兩則訊息同時出現、互相矛盾。不能只看單一欄位是否非空——使用者
    /// 可能是在清空這一欄、靠另一欄符合「至少一項」，因此用 `hasAtLeastOneValue`（三欄合併
    /// 判斷）而不是「這欄非空」。
    private func measurementBinding(_ base: Binding<String>) -> Binding<String> {
        Binding(
            get: { base.wrappedValue },
            set: { newValue in
                base.wrappedValue = newValue
                // `base.wrappedValue` 已寫入新值——`hasAtLeastOneValue` 這裡讀到的是三個
                // `@State` 即時值（三欄合併判斷，不是「這欄非空」；使用者可能正在清空這一欄、
                // 靠另一欄符合「至少一項」）。
                if hasAtLeastOneValue { showsEmptyMessage = false }
            }
        )
    }

    /// Notes `i9Rxq`（C-2）：Measurement Group 下方的群組級固定槽，恆存在，平時 icon 隱藏、
    /// 文字空白——不是欄位級插槽（那個裁決已在 R6 撤回，見「02 Range Warning Slot（C-2）」
    /// 段），三個量測欄本身維持緊湊的 `AppSpacing.item`（16pt）等距。
    private var rangeWarningSlot: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            if let rangeWarning {
                Image(systemName: "exclamationmark.circle").appIconFrame(.small)
                Text(rangeWarning).appFont(.note).lineLimit(isAX3 ? nil : 2)
            }
        }
        .foregroundStyle(Color.lsTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: isAX3 ? nil : Self.slotHeight)
    }

    // MARK: - Footer（Note Field／Status Slot 收在 ScrollView 內，Actions 釘底——見 body）

    private var noteField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("備註（選填）")
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
            TextField("想記錄的小事（選填）", text: $note, axis: .vertical)
                .appFont(.body)
                .foregroundStyle(Color.lsTextPrimary)
                .padding(AppSpacing.label)
                .frame(minHeight: 84, alignment: .top)
                .background(Color.lsSurface, in: RoundedRectangle(cornerRadius: AppSpacing.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                        .strokeBorder(Color.lsControlLine, lineWidth: 1.5)
                )
                .disabled(growthStore.saveState.isSubmitting)
        }
    }

    /// Notes `x7FXr`（M-5）：「至少填一項」的整表訊息在這裡；`showsEmptyMessage` 升級成回話式
    /// 提醒（`$text-primary`），否則是中性提示（`$text-secondary`）——送出失敗（`saveState`
    /// `.failure`）時整段換成後端錯誤文案，同一個插槽、同一個高度，不新增第三種視覺分支。
    private var statusSlot: some View {
        HStack(alignment: .top, spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(statusText).appFont(.note).lineLimit(isAX3 ? nil : 2)
        }
        .foregroundStyle(statusIsEmphasized ? Color.lsTextPrimary : Color.lsTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: isAX3 ? nil : Self.slotHeight)
    }

    private var statusText: String {
        if case .failure(let error) = growthStore.saveState { return error.userFacingMessage }
        if showsEmptyMessage { return "請至少填寫身高、體重、頭圍其中一項，才能儲存這筆紀錄。" }
        return "身高、體重、頭圍至少需要填寫一項。"
    }

    private var statusIsEmphasized: Bool {
        if case .failure = growthStore.saveState { return true }
        return showsEmptyMessage
    }

    /// Notes `x7FXr`／`i9Rxq`：一般字級兩個插槽固定 56pt（`.frame(height:)` 用同一個常數，
    /// 保證 Range Warning Slot／Status Slot 高度逐像素一致）；AX3 改 `fit_content`——呼叫端
    /// 一律 `isAX3 ? nil : Self.slotHeight`，`nil` 讓 `.frame(height:)` 不設限、內容自然撐開。
    private static let slotHeight: CGFloat = 56
    private static let statusSlotID = "growth-form-status-slot"

    private var actions: some View {
        VStack(spacing: AppSpacing.group) {
            // Notes i-7：Save 按鈕拿掉裝飾性 check 圖示，改純文字「儲存」——品牌第 8 條「不
            // disable 儲存」：即使三項全空／超出範圍，這顆鈕永遠可按，按下去才由 `submit()`
            // 決定要不要真的送出 RPC（全空時只顯示提醒、不呼叫 API）。
            PrimaryButton(
                title: "儲存", isLoading: growthStore.saveState.isSubmitting,
                loadingTitle: "正在儲存…", action: submit
            )
            Button(action: cancel) {
                Text("取消")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(Color.lsTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.controlPaddingMedium)
            }
            .disabled(growthStore.saveState.isSubmitting)
        }
    }

    private func submit() {
        guard !growthStore.saveState.isSubmitting else { return }
        guard hasAtLeastOneValue else {
            showsEmptyMessage = true
            statusScrollRequest += 1
            return
        }
        showsEmptyMessage = false
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = GrowthMeasurementInput(
            id: editingRecord?.id, measuredOn: measuredOn,
            heightCm: heightValue, weightKg: weightValue, headCm: headValue,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        Task {
            let saved = await growthStore.save(input)
            if saved { dismiss() } else { statusScrollRequest += 1 }
        }
    }

    private func cancel() {
        guard !growthStore.saveState.isSubmitting else { return }
        dismiss()
    }
}

/// 測量日期的系統日期選擇器——同 `BirthdayPickerSheet` 既有理由與版式（見該檔文件註解），
/// 這裡不重用它：那支是專門給「生日」欄位寫的標籤（`"生日"`／`"選擇生日"`），成長量測是不同
/// 欄位語意，重用會讓兩個不相關情境共用同一組硬寫文案。`in: ...Date()`——量測日期不能選未來
/// （同生日欄位「不能選未來」的既有理由：量測這件事只會發生在過去或今天）。
private struct GrowthMeasurementDatePickerSheet: View {
    @Binding var selection: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("測量日期", selection: $selection, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(AppSpacing.screenPad)
                .navigationTitle("選擇測量日期")
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
#Preview("新增") {
    Color.clear.sheet(isPresented: .constant(true)) {
        GrowthMeasurementFormView(growthStore: .preview())
    }
}

#Preview("編輯") {
    Color.clear.sheet(isPresented: .constant(true)) {
        GrowthMeasurementFormView(
            growthStore: .previewSeededWithDemoRecords(),
            editingRecord: GrowthRecord(
                id: UUID(), familyID: UUID(), childID: UUID(), authorID: GrowthStore.previewAuthorID,
                measuredOn: BirthdayFormat.date(fromWireString: "2026-08-20")!,
                heightCm: 78.5, weightKg: 9.6, headCm: 45.0, note: "打完疫苗，順便量的。",
                createdAt: Date(), updatedAt: Date()
            )
        )
    }
}
#endif
