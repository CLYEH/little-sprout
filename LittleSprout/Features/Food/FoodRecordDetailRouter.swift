import PhotosUI
import SwiftUI

/// 開詳情頁需要、而圖鑑本身不知道的身分資訊（`FoodRecordDetailCopy.actions` 權限三態用）。
struct FoodRecordDetailContext {
    /// 目前登入者；nil＝不是任何一筆的作者。
    let currentUserID: UUID?
    let isFamilyOwner: Bool
}

/// 04 記錄詳情＋它交出來的三條路由（LS-380 R2 接縫①④⑥⑦；LS-381 `FoodRecordDetailRoute`）：
/// - `.edit` → 03b 編輯 sheet（同一支 `FoodRecordSheet`）；儲存 → `onSaved`（圖鑑套用回傳列，詳情頁跟著換新，⑦）。
///   03b 內「刪除這筆記錄」→ 03c → 兩層 sheet 都收起後 `onRemoved`（格子回未吃＋返回圖鑑，④⑥）。
/// - `.delete`（非作者 owner，04c）→ 03c 墊在詳情頁之上（Notes `hqrit` 呼叫路徑②）→ 收起後 `onRemoved`。
/// - `.addPhoto`（04b 空白沖印品）→ 03 的兩種照片來源（Notes `xFvkL`「選好即 upsert media_id」）：選好直接存；
///   存不起來就開 03b（同一顆 store，照片與 03e 失敗句都在），讓使用者看得到原因、按「儲存」重送。
/// - 詳情頁重讀發現這筆已被刪（`isGone`）→ `onRemoved`（④：格子不會停在「吃過」）。
///
/// `onRemoved` 一律等 sheet 自己的 `onDismiss` 才呼叫——sheet 還在收的時候就把詳情頁 pop 掉，會連帶打斷 sheet
/// 的 dismiss（同 `FoodRecordSheet.closeAfterDeleteIfNeeded` 的理由）。
struct FoodRecordDetailRouter: View {
    let child: Child
    let item: FoodCatalogItem
    /// 呼叫端手上最新的那一筆（圖鑑 store 套用過 03b 回傳列之後的值）。
    let record: ChildFoodRecord
    let apiClient: FoodAPIClient
    let context: FoodRecordDetailContext
    let canRecord: Bool
    var detailAPIClient: (any FoodRecordDetailAPIClient)?
    let onSaved: (ChildFoodRecord) -> Void
    /// 這筆記錄不在了（刪除成功或重讀發現已被刪）：呼叫端把格子退回未吃並返回圖鑑。
    let onRemoved: (UUID) -> Void

    private struct EditSession: Identifiable {
        let id = UUID()
        let store: FoodRecordEditorStore
    }

    @State private var editSession: EditSession?
    @State private var deleteTarget: ChildFoodRecord?
    @State private var removedRecordID: UUID?
    @State private var addPhotoStore: FoodRecordEditorStore?
    @State private var pendingPhoto: FoodRecordPhoto?
    @State private var showsSourceChoice = false
    @State private var showsFamilyPicker = false
    @State private var showsPhonePicker = false
    @State private var phoneSelection: PhotosPickerItem?

    var body: some View {
        FoodRecordDetailView(
            child: child, item: item, record: record, apiClient: apiClient,
            currentUserID: context.currentUserID, isFamilyOwner: context.isFamilyOwner, canRecord: canRecord,
            detailAPIClient: detailAPIClient, onGone: onRemoved, onRoute: route
        )
        .sheet(item: $editSession, onDismiss: finishRemovalIfNeeded) { session in
            FoodRecordSheet(
                childName: child.name, store: session.store, apiClient: apiClient,
                onSaved: onSaved, onDeleted: { removedRecordID = $0 }
            )
        }
        .sheet(item: $deleteTarget, onDismiss: finishRemovalIfNeeded) { target in
            FoodRecordDeleteConfirmationSheet(
                foodName: item.nameZh,
                confirmAction: { try await apiClient.deleteChildFoodRecord(id: target.id) },
                onSuccess: { removedRecordID = target.id }
            )
        }
        .confirmationDialog(
            FoodRecordDetailCopy.addPhotoLabel(foodName: item.nameZh), isPresented: $showsSourceChoice,
            titleVisibility: .hidden
        ) {
            Button("從家庭相簿挑") { showsFamilyPicker = true }
            Button("從手機加入") { showsPhonePicker = true }
        }
        .sheet(isPresented: $showsFamilyPicker, onDismiss: savePendingPhoto) {
            FoodFamilyPhotoPickerSheet(
                childID: record.childID, recordDate: BirthdayFormat.localMidnight(from: record.firstTriedOn),
                apiClient: apiClient, initialSelectionID: nil
            ) { photo, _ in pendingPhoto = .family(photo) }
        }
        .photosPicker(isPresented: $showsPhonePicker, selection: $phoneSelection, matching: .images)
        .onChange(of: phoneSelection) { loadPhonePhoto() }
    }

    private func route(_ route: FoodRecordDetailRoute) {
        switch route {
        case .edit(let target):
            editSession = EditSession(store: makeStore(for: target))
        case .delete(let target):
            deleteTarget = target
        case .addPhoto(let target):
            addPhotoStore = makeStore(for: target)
            showsSourceChoice = true
        }
    }

    private func makeStore(for target: ChildFoodRecord) -> FoodRecordEditorStore {
        FoodRecordEditorStore(childID: target.childID, item: item, editingRecord: target, apiClient: apiClient)
    }

    private func finishRemovalIfNeeded() {
        guard let id = removedRecordID else { return }
        removedRecordID = nil
        onRemoved(id)
    }

    /// 03d 收起後才存（「用這張」先記下、`onDismiss` 再送）：存不起來要開 03b，不能跟 03d 的收起動畫搶。
    private func savePendingPhoto() {
        guard let photo = pendingPhoto else { return }
        pendingPhoto = nil
        save(photo)
    }

    private func loadPhonePhoto() {
        guard let picked = phoneSelection else { return }
        phoneSelection = nil
        Task {
            switch await PickedItemLoader.load(picked) {
            case .photo(let data, let fileExtension, let pixelSize, let preview):
                save(.local(LocalFoodPhoto(
                    data: data, fileExtension: fileExtension, pixelSize: pixelSize, preview: preview
                )))
            case .video, .unsupportedFormat, .none:
                guard let store = addPhotoStore else { return }
                store.photoLoadFailed = true
                editSession = EditSession(store: store)
            }
        }
    }

    /// 04b「選好即 upsert media_id」：沿用 03b 的送出狀態機（其餘欄位原樣帶回、手機照片先上傳）。
    private func save(_ photo: FoodRecordPhoto) {
        guard let store = addPhotoStore else { return }
        store.photo = photo
        Task {
            if let saved = await store.save() {
                addPhotoStore = nil
                onSaved(saved)
            } else {
                editSession = EditSession(store: store)
            }
        }
    }
}
