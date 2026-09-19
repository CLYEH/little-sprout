import SwiftUI

/// 測量日期的系統日期選擇器——同 `BirthdayPickerSheet` 既有理由與版式（見該檔文件註解），
/// 這裡不重用它：那支是專門給「生日」欄位寫的標籤（`"生日"`／`"選擇生日"`），成長量測是不同
/// 欄位語意，重用會讓兩個不相關情境共用同一組硬寫文案。`in: ...Date()`——量測日期不能選未來
/// （同生日欄位「不能選未來」的既有理由：量測這件事只會發生在過去或今天）。
///
/// R2 merge-review R2-M1（orchestrator 裁決 `8036a6f0`）：從 `GrowthMeasurementFormView.swift`
/// 拆成獨立檔案——加完 `submitDecision`／`showsInvalidMessage` 後那支檔案超過 SwiftLint
/// `file_length` 上限，同 `AlbumDetailView+Actions.swift` 從 `AlbumDetailView.swift` 拆分的既有
/// 先例。不標 `private`（同既有先例，`private` 以檔案為界，`GrowthMeasurementFormView.swift`
/// 跨檔案存取不到）。
struct GrowthMeasurementDatePickerSheet: View {
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
