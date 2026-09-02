import Foundation
import Observation
import UIKit

/// 日記編輯器（LS-125，`design/littlesprout.pen` `LS-21 / 12*` 系列）的 `@Observable` 狀態
/// 管理——畫面等級的暫存草稿，每次開編輯器建立一份新的，不像 `ChildrenStore`／`FamilyStore`
/// 那樣隨 app 存活（草稿不需要跨畫面共享）。
///
/// 送出流程（`publish()`）在本檔最下方：`publishState` 是 `private(set)`，Swift 的 `private`
/// 是檔案範圍而非型別範圍，拆成另一個 extension 檔會寫不到這個屬性，見該段落文件註解。純
/// 佇列／選取／排序／歸屬狀態機（本檔上半部）不必經過任何 async I/O 就能被單元測試覆蓋。
@MainActor
@Observable
final class DiaryComposerStore {
    /// 每篇日記最多 20 張（LS-125 票文 Scope 2）。
    static let photoCapacity = 20

    let familyID: UUID
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService

    var body = ""
    var entryDate = Date()
    private(set) var photos: [DiaryPhotoDraft] = []
    var selectedPhotoIDs: Set<UUID> = []
    /// 空集合＝「不指定」（`design/littlesprout.pen` `zgVn0`：兩者互斥，空集合天然就是不指定，
    /// 不另外維護一顆會跟這裡失去同步的布林旗標）。
    var selectedChildIDs: Set<UUID> = []
    private(set) var publishState: DiaryPublishState = .idle

    init(familyID: UUID, diaryAPIClient: DiaryAPIClient, mediaUploadService: MediaUploadService) {
        self.familyID = familyID
        self.diaryAPIClient = diaryAPIClient
        self.mediaUploadService = mediaUploadService
    }

    // MARK: - 佇列容量

    var remainingSlots: Int { max(0, Self.photoCapacity - photos.count) }
    var isAtCapacity: Bool { photos.count >= Self.photoCapacity }

    /// 12g：佇列裡任何一支超過 60 秒的影片都各自顯示一行「這支影片 M:SS…」回話。
    var overLongVideoDrafts: [DiaryPhotoDraft] { photos.filter(\.exceedsPublishDuration) }

    // MARK: - 新增

    @discardableResult
    func addPhoto(
        data: Data, fileExtension: String, pixelSize: PixelSize, previewImage: UIImage?
    ) -> DiaryPhotoAddOutcome {
        guard !isAtCapacity else { return .capacityReached }
        photos.append(DiaryPhotoDraft(
            kind: .photo(data: data, fileExtension: fileExtension),
            previewImage: previewImage, pixelSize: pixelSize
        ))
        return .added
    }

    @discardableResult
    func addVideo(
        fileURL: URL, fileExtension: String, duration: TimeInterval,
        pixelSize: PixelSize, previewImage: UIImage?
    ) -> DiaryPhotoAddOutcome {
        guard !isAtCapacity else { return .capacityReached }
        photos.append(DiaryPhotoDraft(
            kind: .video(fileURL: fileURL, fileExtension: fileExtension, duration: duration),
            previewImage: previewImage, pixelSize: pixelSize
        ))
        return .added
    }

    // MARK: - 選取／移除（12d：單擊縮圖＝勾選，可複選）

    func toggleSelection(_ id: UUID) {
        if selectedPhotoIDs.remove(id) == nil {
            selectedPhotoIDs.insert(id)
        }
    }

    func isSelected(_ id: UUID) -> Bool { selectedPhotoIDs.contains(id) }

    /// 「移除所選 N 張」——N=0 時 UI 層整個節點不出現（見 `DiaryPhotosSection`），這裡不用
    /// 額外防呆：空集合呼叫這支方法本來就是安全的 no-op。
    func removeSelected() {
        guard !selectedPhotoIDs.isEmpty else { return }
        photos.removeAll { selectedPhotoIDs.contains($0.id) }
        selectedPhotoIDs.removeAll()
    }

    // MARK: - 排序（12e：長按拖曳；VoiceOver 對等路徑見 `v0tLp` R6）

    /// 拖曳放開後的最終落點——`fromID` 位置抽出、插進 `toIndex`（越界會被夾住）。
    func move(id: UUID, toIndex targetIndex: Int) {
        guard let sourceIndex = photos.firstIndex(where: { $0.id == id }) else { return }
        let clampedTarget = min(max(0, targetIndex), photos.count - 1)
        guard sourceIndex != clampedTarget else { return }
        let item = photos.remove(at: sourceIndex)
        photos.insert(item, at: clampedTarget)
    }

    /// VoiceOver `accessibilityCustomActions`「往前移」——已經是第一張時安靜地不做事（陣列
    /// 不循環，同 R4 訂正過的邊界規則，只是這裡不再需要額外回話：R6 把可見的邊界回話列一併
    /// 隨 Reorder Controls 除役，見 `design/littlesprout.pen` Handoff Notes `MA9dz`）。
    func moveEarlier(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }), index > 0 else { return }
        photos.swapAt(index, index - 1)
    }

    /// VoiceOver「往後移」，同上。
    func moveLater(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }), index < photos.count - 1 else { return }
        photos.swapAt(index, index + 1)
    }

    // MARK: - 寶貝歸屬（`zgVn0`：多選，「不指定」與其他互斥）

    func toggleChild(_ id: UUID) {
        if selectedChildIDs.remove(id) == nil {
            selectedChildIDs.insert(id)
        }
    }

    func selectUnspecifiedChild() {
        selectedChildIDs.removeAll()
    }

    var isUnspecifiedChild: Bool { selectedChildIDs.isEmpty }

    // MARK: - 送出狀態重置

    /// 12c 發佈失敗後使用者修改內容再試一次前呼叫；成功／進行中不動作。
    func resetPublishFailure() {
        guard case .failure = publishState else { return }
        publishState = .idle
    }

    // MARK: - 送出（`publishState` 是 `private(set)`，Swift 的 `private` 是檔案範圍——這支
    // 方法組必須留在本檔，不能像 `+Photos.swift`／`+Fields.swift` 那樣切到另一個 extension
    // 檔，否則寫不到這個屬性；本檔目前長度還在 SwiftLint 預設上限內，不需要為了拆檔犧牲
    // 封裝，見 DoD「送出流程」段）。
    //
    // 已知取捨（重試不是續傳）：失敗後使用者按「發佈日記」會整個重新跑一次
    // `uploadAllMedia()`，不會記得上一次已經成功上傳到一半的照片——若失敗發生在第 N 張之後，
    // 前 N 張會在 Storage／`media` 留下沒有掛上任何日記的孤兒列（不影響功能，只是浪費一點
    // 儲存額度）。做到「續傳、不重複上傳」需要在草稿裡追蹤「這張的 media id 是否已經成功」，
    // 屬於本票 Scope 沒有要求的完整度，記在 handoff 風險欄，留給之後有真實重試率數據時再評估
    // 要不要做。

    @discardableResult
    func publish() async -> Bool {
        guard !publishState.isInFlight else { return false }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            publishState = .failure(.validationRetryable(message: "日記還沒寫內容，加幾個字再發佈吧。", code: nil))
            return false
        }
        publishState = .uploading
        do {
            let mediaIDs = try await uploadAllMedia()
            let diaryID = try await diaryAPIClient.createDiaryEntry(
                familyID: familyID, body: trimmedBody, entryDate: entryDate, childIDs: Array(selectedChildIDs)
            )
            try await diaryAPIClient.attachMedia(diaryID: diaryID, familyID: familyID, mediaIDs: mediaIDs)
            publishState = .success
            return true
        } catch let error as AppError {
            publishState = .failure(error)
            return false
        } catch {
            publishState = .failure(AppError.map(error))
            return false
        }
    }

    /// 依佇列順序逐張上傳（刻意序列、不平行：20 張上限下平行上傳省下的時間有限，序列化換來
    /// 「失敗時只有一張正在傳、容易對應到是哪一張」的除錯簡單性，見 handoff）。影片超過 60 秒
    /// 先用 `VideoTrimmer` 裁切壓縮，回傳的暫存檔才是真正拿去上傳的那份。
    private func uploadAllMedia() async throws -> [UUID] {
        var mediaIDs: [UUID] = []
        for draft in photos {
            switch draft.kind {
            case .photo(let data, let fileExtension):
                let id = try await mediaUploadService.uploadPhoto(
                    familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: draft.pixelSize
                )
                mediaIDs.append(id)
            case .video(let fileURL, let fileExtension, let duration):
                let source = try await VideoTrimmer.trimmedIfNeeded(
                    fileURL: fileURL, fileExtension: fileExtension, duration: duration
                )
                let id = try await mediaUploadService.uploadVideo(
                    familyID: familyID, fileURL: source.fileURL, fileExtension: source.fileExtension,
                    // 裁切／壓縮輸出保持原始比例夾在 1080p 內，沿用原始草稿量到的像素尺寸——
                    // 見 VideoTrimmer 文件註解的已知取捨。
                    pixelSize: draft.pixelSize
                )
                mediaIDs.append(id)
            }
        }
        return mediaIDs
    }
}
