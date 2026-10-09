import Foundation
import Observation
import UIKit

/// 03 sheet 的送出狀態（同 `GrowthOperationState` 的形狀，不借用成長區塊的型別）。
enum FoodRecordSaveState: Equatable {
    case idle
    case submitting
    case failure(AppError)

    var isSubmitting: Bool { self == .submitting }
}

/// 照片欄目前選了什麼：沒選／家庭相簿的一張（03d「用這張」）／從手機剛挑、還沒上傳的一張。
enum FoodRecordPhoto: Equatable {
    case none
    case family(FamilyPhoto)
    case local(LocalFoodPhoto)

    /// 送出時的 `media_id`（家庭照片直接用；手機照片要先上傳，見 `FoodRecordEditorStore.save`）。
    var familyMediaID: UUID? {
        if case .family(let photo) = self { return photo.id }
        return nil
    }

    /// 手機照片的 `LocalFoodPhoto.id`（LS-430：判斷「換掉的是不是已上傳的那張」）。
    var localPhotoID: UUID? {
        if case .local(let photo) = self { return photo.id }
        return nil
    }
}

/// 「從手機加入」挑到、已讀進記憶體的一張照片（`PickedItemLoader.LoadedItem.photo` 的值）。`id` 只用來
/// 辨識「是不是同一張」——重試時同一張不重傳（見 `FoodRecordEditorStore.uploadedLocalPhoto`）。
struct LocalFoodPhoto: Equatable {
    let id = UUID()
    let data: Data
    let fileExtension: String
    let pixelSize: PixelSize
    let preview: UIImage?

    static func == (lhs: LocalFoodPhoto, rhs: LocalFoodPhoto) -> Bool { lhs.id == rhs.id }
}

/// 03／03b sheet 的畫面狀態（view-scoped，每次開 sheet 建一份，同 `DiaryComposerStore` 的分工）。
///
/// **送出（`save()`）的競態規則**（票文 R1）：
/// - 連點：`saveState.isSubmitting` 在 MainActor 上同步檢查＋設定，第二下在同一個 runloop 內就被擋掉，
///   不會排出兩個 upsert（RPC 端的 `ON CONFLICT` 也只會留一列，這裡是讓 UI 不發第二次）。
/// - 失敗後重送：手機照片若已上傳成功，記住「這張 → media id」，重送不重傳（不在 Storage 留第二份）；
///   使用者換了一張才會重新上傳。
/// - sheet 關閉中回呼：`save()` 回傳儲存好的列、由呼叫端決定要不要套用（`FoodBookStore.applySaved` 會
///   再檢查孩子是否仍相同）；sheet 本身在送出期間 `.interactiveDismissDisabled`，不會在半途被拖掉。
@MainActor
@Observable
final class FoodRecordEditorStore {
    let childID: UUID
    let item: FoodCatalogItem
    /// nil＝第一次記錄（03）；非 nil＝編輯這一筆（03b，帶入既有值）。
    let editingRecord: ChildFoodRecord?
    private let apiClient: FoodAPIClient

    var firstTriedOn: Date
    var reaction: FoodReaction?
    /// Notes `m18MTy`：≤2000 字（`child_food_records` CHECK）——超過的部分直接截掉，不讓送出才撞 23514。
    var note: String {
        didSet { if note.count > Self.noteLimit { note = String(note.prefix(Self.noteLimit)) } }
    }
    var photo: FoodRecordPhoto = .none {
        didSet {
            guard photo != oldValue else { return }
            if photoLoadFailed { photoLoadFailed = false }
            // LS-430：換一張／不用照片時，先前上傳了、但記錄沒綁上的那張手機照片不再有人要。
            if let uploadedLocalPhoto, photo.localPhotoID != uploadedLocalPhoto.localID {
                Task { await abandonUnboundUpload() }
            }
        }
    }
    /// 「從手機加入」讀不出照片（格式不支援等）——Status Slot 顯示 `FoodRecordCopy.photoUnsupported`。
    var photoLoadFailed = false
    private(set) var saveState: FoodRecordSaveState = .idle
    /// 已上傳成功的手機照片（`LocalFoodPhoto.id` → `media.id`），見類型文件「失敗後重送」。
    private var uploadedLocalPhoto: (localID: UUID, mediaID: UUID)?
    /// LS-430：上傳後有任何一次 upsert 失敗「可能已送達伺服器」（逾時／5xx：伺服器可能已提交、照片其實已綁定）。
    /// 為 true 時放棄不得軟刪——軟刪一張可能已綁在記錄上的照片會讓記錄顯示「照片沒有載入」；交給後端
    /// 每日清理兜底（它認得有效飲食記錄的引用）。一旦為 true 就不再回到 false。
    private var uploadMayBeBound = false

    static let noteLimit = 2000

    init(
        childID: UUID, item: FoodCatalogItem, editingRecord: ChildFoodRecord? = nil, apiClient: FoodAPIClient,
        now: Date = Date()
    ) {
        self.childID = childID
        self.item = item
        self.editingRecord = editingRecord
        self.apiClient = apiClient
        // `first_tried_on` 解成 UTC 午夜；DatePicker 與送出都以裝置本地時區的那一天為準（同
        // `GrowthMeasurementFormView.localMidnight` 的既有修法）。
        firstTriedOn = editingRecord.map { BirthdayFormat.localMidnight(from: $0.firstTriedOn) } ?? now
        existingPhotoLoad = editingRecord?.mediaID == nil ? .notApplicable : .loading
        reaction = editingRecord?.reaction.flatMap(FoodReaction.init(rawValue:))
        note = editingRecord?.note ?? ""
    }

    var isEditing: Bool { editingRecord != nil }

    /// Notes `m18MTy`：已選再點一次＝取消。
    func toggleReaction(_ tapped: FoodReaction) {
        reaction = reaction == tapped ? nil : tapped
    }

    /// 03b 既有照片縮圖的讀取狀態（merge-review R1 i4）。
    enum ExistingPhotoLoad: Equatable {
        /// 第一次記錄，或這筆本來就沒照片。
        case notApplicable
        case loading
        /// 讀不到（已軟刪／網路）——畫面顯示「原照片讀取失敗」、仍保留原 `media_id`，可按「不用照片」清掉。
        case failed
    }

    private(set) var existingPhotoLoad: ExistingPhotoLoad = .notApplicable

    /// 照片欄目前代表「原本那張、還沒讀到縮圖」：畫面顯示選取態（換一張／不用照片），送出也保留原 `media_id`
    /// ——畫面與送出值一致（R1 i4：原本這裡顯示「沒選照片」、送出卻帶原 `media_id`、又沒有「不用照片」可按）。
    var keepsUnresolvedExistingPhoto: Bool {
        photo == .none && !removedExistingPhoto && editingRecord?.mediaID != nil
    }

    /// 03b 回填既有照片的縮圖（`media_id` → `FamilyPhoto`）。讀不到就標 `.failed`，照片欄照樣是選取態（見
    /// `keepsUnresolvedExistingPhoto`），送出仍保留原 `media_id`，不因縮圖讀不到就默默把照片拿掉。
    func loadExistingPhoto() async {
        guard let mediaID = editingRecord?.mediaID, photo == .none, !removedExistingPhoto else { return }
        existingPhotoLoad = .loading
        let existing = try? await apiClient.fetchFamilyPhoto(id: mediaID)
        guard photo == .none, !removedExistingPhoto else { return }
        if let existing {
            photo = .family(existing)
            existingPhotoLoad = .notApplicable
        } else {
            existingPhotoLoad = .failed
        }
    }

    /// 使用者在 03b 按「不用照片」——明確要求 `media_id = null`（Notes `COtpI`）。
    private(set) var removedExistingPhoto = false

    func removePhoto() {
        photo = .none
        removedExistingPhoto = true
    }

    /// 送出。成功回傳儲存好的列（呼叫端負責套用到圖鑑並關 sheet）；失敗回傳 nil、`saveState = .failure`。
    func save() async -> ChildFoodRecord? {
        guard !saveState.isSubmitting else { return nil }
        saveState = .submitting
        do {
            let mediaID = try await resolvedMediaID()
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = try await apiClient.upsertChildFoodRecord(FoodRecordUpsert(
                childID: childID, foodID: item.id, firstTriedOn: firstTriedOn, mediaID: mediaID,
                note: trimmedNote.isEmpty ? nil : trimmedNote, reaction: reaction
            ))
            saveState = .idle
            uploadedLocalPhoto = nil  // 已綁定到記錄，不再是孤兒（LS-430）
            return saved
        } catch {
            let mapped = AppError.map(error)
            if uploadedLocalPhoto != nil, Self.mayHaveReachedServer(mapped) { uploadMayBeBound = true }
            saveState = .failure(mapped)
            return nil
        }
    }

    /// LS-430：放棄（取消／換一張／不用照片）時，把先前「從手機加入」上傳成功、但 `upsert_child_food_record` 沒有
    /// 套用的那張照片軟刪（`media.deleted_at`），不留孤兒佔用額度。只有失敗已確定是伺服器拒絕時才軟刪（見
    /// `uploadMayBeBound`）；軟刪本身失敗（離線等）就算了——後端每日清理會掃掉「無任何引用的 24 小時前 media」。
    func abandonUnboundUpload() async {
        guard let uploaded = uploadedLocalPhoto else { return }
        uploadedLocalPhoto = nil
        guard !uploadMayBeBound else { return }
        try? await apiClient.softDeleteMedia(mediaIDs: [uploaded.mediaID])
    }

    /// 網路中斷／逾時／5xx：請求可能已經在伺服器提交；`.rejected`／`.validationRetryable` 是伺服器明確拒絕。
    private static func mayHaveReachedServer(_ error: AppError) -> Bool {
        switch error {
        case .network, .server, .retryableSystem: true
        case .rejected, .validationRetryable: false
        }
    }

    /// 03c：軟刪這一筆（只有編輯模式有；第一次記錄模式不顯示刪除鈕，呼叫到就是程式錯誤、大聲失敗）。
    func delete() async throws {
        guard let editingRecord else { throw AppError.server(message: "沒有可刪除的記錄", code: nil) }
        try await apiClient.deleteChildFoodRecord(id: editingRecord.id)
    }

    /// PUT 語意（upsert 整組替換）：沒碰照片欄＝保留原本的 `media_id`（包含縮圖讀不到的情況）。
    private func resolvedMediaID() async throws -> UUID? {
        switch photo {
        case .family(let familyPhoto):
            return familyPhoto.id
        case .local(let local):
            if let uploadedLocalPhoto, uploadedLocalPhoto.localID == local.id { return uploadedLocalPhoto.mediaID }
            let mediaID = try await apiClient.uploadPhoto(
                childID: childID, data: local.data, fileExtension: local.fileExtension, pixelSize: local.pixelSize
            )
            uploadedLocalPhoto = (local.id, mediaID)
            return mediaID
        case .none:
            return removedExistingPhoto ? nil : editingRecord?.mediaID
        }
    }
}
