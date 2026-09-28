import PhotosUI
import SwiftUI

/// `FoodRecordSheet` 疊上去的第二層（03d 挑相簿／03c 刪除確認）與照片來源的載入——從主檔拆出
/// （`type_body_length`，同 `FoodBookView+States.swift` 的既有拆檔先例）。
extension FoodRecordSheet {
    /// 03d（`OoYLu`）：「用這張」才回填 `media_id`（Notes `uniIm`：選中＝純 UI 狀態）。
    var familyPicker: some View {
        FoodFamilyPhotoPickerSheet(
            childID: store.childID, recordDate: store.firstTriedOn, apiClient: apiClient,
            initialSelectionID: store.photo.familyMediaID
        ) { photo, url in
            if let url { photoURLs[photo.displayPath] = url }
            store.photo = .family(photo)
        }
    }

    /// 03c（`Oob1d`）：沿 LS-152 操作表語彙重用 `DeleteConfirmationSheet`——刪除鈕與取消釘在 ScrollView
    /// 外，任何字級都在首屏內（AX3 亦是，稿 `d56YR`）；背景是呼叫端當下的畫面（本 sheet 疊在 03b 之上，
    /// 刻意偏離 LS-152 的空背景慣例，Notes `GssPy`）。
    var deleteConfirmation: some View {
        DeleteConfirmationSheet(
            headTitle: FoodRecordCopy.deleteTitle(foodName: store.item.nameZh),
            bodyText: FoodRecordCopy.deleteBody(foodName: store.item.nameZh),
            confirmLabel: "刪除這筆記錄",
            confirmAction: { try await store.delete() },
            // `DeleteConfirmationSheet` 保證先關自己再呼叫 `onSuccess`（LS-190 R2 m3）——這裡才讓呼叫端把
            // 格子退回「還沒吃」，再等確認 sheet 關完（`onDismiss`）關本 sheet。
            onSuccess: {
                if let id = store.editingRecord?.id { onDeleted(id) }
                closesAfterDeleteConfirmation = true
            }
        )
    }

    func closeAfterDeleteIfNeeded() {
        guard closesAfterDeleteConfirmation else { return }
        closesAfterDeleteConfirmation = false
        dismiss()
    }

    /// 「從手機加入」：`PickedItemLoader` 讀出位元組＋尺寸＋預覽縮圖（解碼在它自己的 async 路徑，不在
    /// 主執行緒上解整張原圖）；上傳延到按「儲存」時才做（`FoodRecordEditorStore.save`），取消就不留孤兒檔。
    func loadPhonePhoto() {
        guard let item = phoneSelection else { return }
        phoneSelection = nil
        Task {
            switch await PickedItemLoader.load(item) {
            case .photo(let data, let fileExtension, let pixelSize, let preview):
                store.photo = .local(LocalFoodPhoto(
                    data: data, fileExtension: fileExtension, pixelSize: pixelSize, preview: preview
                ))
            case .video, .unsupportedFormat, .none:
                store.photoLoadFailed = true
            }
        }
    }

    /// 03b 回填的既有照片（或 03d 選的但還沒簽名的）補一次縮圖簽名 URL。
    func signSelectedFamilyPhotoIfNeeded() async {
        guard case .family(let photo) = store.photo, photoURLs[photo.displayPath] == nil else { return }
        if let urls = try? await apiClient.signedURLs(forStoragePaths: [photo.displayPath]) {
            photoURLs.merge(urls) { _, new in new }
        }
    }
}

/// 第一次吃的日期——系統日期選擇器（同 `GrowthMeasurementDatePickerSheet` 的版式與理由），`in: ...Date()`：
/// 第一次吃到只會發生在過去或今天（可回填，Notes `m18MTy`）。
struct FoodRecordDatePickerSheet: View {
    @Binding var selection: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker(FoodRecordCopy.dateLabel, selection: $selection, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding(AppSpacing.screenPad)
                .navigationTitle("選擇日期")
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
