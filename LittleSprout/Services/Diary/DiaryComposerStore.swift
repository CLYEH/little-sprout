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

    /// `didSet` 兩件事：① 開始有內容就清掉「還沒寫內容」提示；② 使用者在 12c 失敗態下修改
    /// 內容代表要重試了，先把舊的失敗態收掉（merge-review R1 m5：`resetPublishFailure` 原本
    /// 是沒有任何呼叫端的死碼，這裡接上）。
    var body = "" {
        didSet {
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showsEmptyBodyMessage = false
            }
            resetPublishFailure()
        }
    }
    var entryDate = Date()
    private(set) var photos: [DiaryPhotoDraft] = []
    var selectedPhotoIDs: Set<UUID> = []
    /// 空集合＝「不指定」（`design/littlesprout.pen` `zgVn0`：兩者互斥，空集合天然就是不指定，
    /// 不另外維護一顆會跟這裡失去同步的布林旗標）。`AttributionSheet` 是通用元件（只認
    /// `Binding<Set<UUID>>`，未來相簿也要重用），互斥切換邏輯就地寫在那裡的 `Binding`
    /// 上，不透過 store 方法（merge-review R1 m5：先前在這裡另外放了一份
    /// `toggleChild`/`selectUnspecifiedChild`，`AttributionSheet` 從未呼叫、是新引入的
    /// 死碼，已移除；本輪新增的測試改直接對 `selectedChildIDs` 賦值）。
    var selectedChildIDs: Set<UUID> = []
    private(set) var publishState: DiaryPublishState = .idle
    /// 空內文不算「送出失敗」——沒有打過任何網路請求，借用 `.failure(AppError)` 會讓畫面顯示
    /// 「你寫的內容還在，可以直接重試」這種對「根本還沒送出」語意矛盾的文案（merge-review R1
    /// M1／m10）。改成獨立旗標，UI 端在內文欄位旁就地顯示提示，不進 Action Bar 的失敗態。
    private(set) var showsEmptyBodyMessage = false
    /// `loadPicked`（`DiaryEditorView+Photos.swift`）逐張非同步解碼期間為 `true`——`publish()`
    /// 用它擋下「照片還在載入時按發佈」會靜默漏掉尚未 append 進 `photos` 的照片這個問題
    /// （merge-review R1 M3）；發佈鈕與「新增照片」cell 也讀這顆旗標決定要不要停用（M3／m6
    /// 同一顆旗標一起解，見 Handoff）。
    private(set) var isLoadingPickedItems = false
    /// 上一批挑選裡有幾個檔案因格式不支援被跳過（`PickedItemLoader.LoadedItem
    /// .unsupportedFormat`）——常駐回話列用，下一批挑選開始時歸零（merge-review R1 m4）。
    private(set) var unsupportedFormatSkippedCount = 0

    /// 已成功建立的日記 id——`publish()` 失敗後重試時若已經有值就跳過 `createDiaryEntry`，
    /// 避免重複建立（merge-review R1 M2）。
    private var createdDiaryID: UUID?
    /// 建立／最近一次同步到後端當下的內容——重試時若目前的 `body`／`entryDate`／
    /// `selectedChildIDs` 跟這份快照不同，代表使用者在失敗後編輯過（`resetPublishFailure`
    /// 讓失敗態下這三個欄位都還能編輯），要先呼叫 `updateDiaryEntry` 把新內容送上去，不能
    /// 只是重用舊 id 直接跳去 `attachMedia`（merge-review R2 N1：先前的 memoized 分支收了
    /// `body`／`childIDs` 參數卻整組沒用，重試會用「建立當下」的舊內容成功、`publishState`
    /// 變成 `.success`、畫面 dismiss，但時間軸上留下的是改之前的版本——使用者看到「成功」，
    /// 實際送出去的不是他剛剛改過的內容）。
    private var createdDiarySnapshot: DiaryContentSnapshot?
    /// 草稿 id → 已上傳成功的 media id——重試時已經上傳過的照片／影片不會重傳
    /// （merge-review R1 M2）。用草稿 id 對應（不是陣列 index）：使用者可能在失敗後、重試前
    /// 編輯佇列（移除某張），這樣做仍能正確地「這張傳過了就不用再傳，那張沒傳過的繼續傳」。
    private var uploadedMediaByDraftID: [UUID: UUID] = [:]
    /// `cleanupRemovedDrafts` 呼叫 `softDeleteMedia` 失敗時暫存的 media id（LS-212 R2，
    /// merge-review R1 m1）——最常見的失敗原因（斷線）跟觸發清理的原因往往是同一個，草稿的
    /// `uploadedMediaByDraftID` 記錄已經在同一次呼叫裡被拿走，若直接丟掉這批 id 就永遠沒有
    /// 重試機會。留在這裡，下一次 `cleanupRemovedDrafts`（不論是再移除一張、還是最終
    /// `discardDraft()`）會把它們併入這次的批次一起重送；同一個 store 存活期間內失敗會持續
    /// 累積，成功後清空。
    private var pendingOrphanMediaIDs: Set<UUID> = []

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

    // MARK: - 挑選載入中（M3／m6）

    func beginLoadingPickedItems() {
        isLoadingPickedItems = true
        unsupportedFormatSkippedCount = 0
    }

    func endLoadingPickedItems() {
        isLoadingPickedItems = false
    }

    func reportUnsupportedFormatSkipped(count: Int) {
        guard count > 0 else { return }
        unsupportedFormatSkippedCount += count
    }

    // MARK: - 選取／移除（12d：單擊縮圖＝勾選，可複選）

    func toggleSelection(_ id: UUID) {
        if selectedPhotoIDs.remove(id) == nil {
            selectedPhotoIDs.insert(id)
        }
    }

    func isSelected(_ id: UUID) -> Bool { selectedPhotoIDs.contains(id) }

    /// 「移除所選 N 張」——N=0 時 UI 層整個節點不出現（見 `DiaryPhotosSection`），這裡不用
    /// 額外防呆：空集合呼叫這支方法本來就是安全的 no-op。**LS-212**：改成 `async`——移除的
    /// 草稿若已經上傳過（`uploadedMediaByDraftID` 有記錄）要主動軟刪對應 `media` 列，影片
    /// 草稿的本機暫存檔也要清掉，兩者都是網路／檔案系統操作（見 `cleanupRemovedDrafts`，依
    /// LS-96 `d8634a08` R4 補充）。呼叫端（`removeSelectedButton`）在 `publishState
    /// .isInFlight` 時本來就 `.disabled`，跟 `uploadAllMedia()` 不會有同時搶 `photos`／
    /// `uploadedMediaByDraftID` 的競態。
    func removeSelected() async {
        guard !selectedPhotoIDs.isEmpty else { return }
        let removed = photos.filter { selectedPhotoIDs.contains($0.id) }
        photos.removeAll { selectedPhotoIDs.contains($0.id) }
        selectedPhotoIDs.removeAll()
        await cleanupRemovedDrafts(removed)
    }

    /// 使用者按「取消」整個放棄編輯器（未成功發佈）時呼叫——同 `removeSelected` 的清理，範圍
    /// 是佇列裡目前還留著的**每一張**，不只是被選取的那些（LS-212）。成功發佈後不清——那些
    /// `media` 列已經合法 attach，不是孤兒。呼叫端（`cancelButton`）同樣在
    /// `publishState.isInFlight` 時 `.disabled`，理由同上。
    func discardDraft() async {
        guard publishState != .success else { return }
        await cleanupRemovedDrafts(photos)
    }

    /// 草稿被移除（`removeSelected`）或整個編輯器被放棄（`discardDraft`）時的收尾：影片草稿
    /// 清掉本機暫存檔（`TransferableVideoFile` 複製檔／`VideoTrimmer` 裁切輸出，見
    /// `MediaDraftTempStorage`）；已經上傳成功過的草稿（`uploadedMediaByDraftID` 有記錄）
    /// 主動軟刪對應 `media` 列——不論它當下有沒有被 `attachMedia` 掛上（LS-96 `d8634a08`
    /// R4 補充：`attachMedia` 的 merge-duplicates upsert 只 `INSERT`／`UPDATE`、不
    /// `DELETE`，若上一輪其實已經 commit、只是回應遺失，不主動處理這一列就會永遠留在已發佈
    /// 的日記裡）。
    ///
    /// **LS-212 R2（merge-review R1 m1）**：`softDeleteMedia` 失敗時把這批 id 移進
    /// `pendingOrphanMediaIDs`、留到下一次呼叫重試，不是直接丟掉——最常見的失敗成因（斷線）
    /// 跟「使用者接著移除草稿」這個觸發清理的動作往往同時發生，原本在 `await` **之前**就
    /// `removeValue` 掉、又用 `try?` 吞錯的寫法，會讓最可能觸發本修法的情境剛好是它幾乎必定
    /// 無效的情境。best-effort 的定位不變：這裡仍不會把錯誤往外拋、不阻斷任何 UI 流程，只是
    /// 「失敗至少留下重試的資料」而不是「連再試一次的機會都沒有」。
    private func cleanupRemovedDrafts(_ removed: [DiaryPhotoDraft]) async {
        for draft in removed {
            if case .video(let fileURL, _, _) = draft.kind {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        let newOrphanMediaIDs = removed.compactMap { uploadedMediaByDraftID.removeValue(forKey: $0.id) }
        let candidateMediaIDs = pendingOrphanMediaIDs.union(newOrphanMediaIDs)
        guard !candidateMediaIDs.isEmpty else { return }
        do {
            try await mediaUploadService.softDeleteMedia(mediaIDs: Array(candidateMediaIDs))
            pendingOrphanMediaIDs.removeAll()
        } catch {
            pendingOrphanMediaIDs = candidateMediaIDs
        }
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

    var isUnspecifiedChild: Bool { selectedChildIDs.isEmpty }

    // MARK: - 送出狀態重置

    /// 12c 發佈失敗後使用者修改內容再試一次前呼叫（`body` 的 `didSet` 已接上）；成功／進行中
    /// ／閒置不動作。刻意**不**清空 `createdDiaryID`／`uploadedMediaByDraftID`：清掉會讓 M2
    /// 的續傳保護失效，使用者只是在失敗後改個字，不代表要放棄已經成功的那幾步。
    func resetPublishFailure() {
        guard case .failure = publishState else { return }
        publishState = .idle
    }

    // MARK: - 送出（`publishState` 是 `private(set)`，Swift 的 `private` 是檔案範圍——這支
    // 方法組必須留在本檔，不能像 `+Photos.swift`／`+Fields.swift` 那樣切到另一個 extension
    // 檔，否則寫不到這個屬性；本檔目前長度還在 SwiftLint 預設上限內，不需要為了拆檔犧牲
    // 封裝，見 DoD「送出流程」段）。

    @discardableResult
    func publish() async -> Bool {
        // merge-review R2 n2（防禦性）：成功之後理論上呼叫端會立刻 dismiss、不會再呼叫
        // `publish()`（`store` 是畫面等級的 `@State`，成功後那個實例就沒有下一次送出的機會），
        // 但 `resolveDiaryID` 的記憶本身沒有任何 invalidate 條件，這裡補一道底線，不完全依賴
        // 呼叫端的使用方式維持正確性。
        guard !publishState.isInFlight, publishState != .success, !isLoadingPickedItems else { return false }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            showsEmptyBodyMessage = true
            return false
        }
        showsEmptyBodyMessage = false
        publishState = .uploading
        do {
            let mediaIDs = try await uploadAllMedia()
            let diaryID = try await resolveDiaryID(
                body: trimmedBody, entryDate: entryDate, childIDs: Array(selectedChildIDs)
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

    /// 已經成功建立過就直接回傳既有 id，不再重複呼叫 `create_diary_entry`（merge-review R1
    /// M2：失敗態常見成因是 `attachMedia` 撞到連線中斷，而不是 `createDiaryEntry` 本身失敗
    /// ——那一步的成果不該被重試白白丟棄，否則使用者重試幾次、時間軸上就多幾篇重複貼文）。
    /// **R2 N1**：memoized 分支現在會比對 `createdDiarySnapshot`——內容跟建立當下不同就先
    /// `updateDiaryEntry`（全專案唯一沒有呼叫端的 RPC，見 R1 I5），確保重試送出的是使用者
    /// 剛剛編輯過的版本，不是靜默沿用舊內容。
    private func resolveDiaryID(body: String, entryDate: Date, childIDs: [UUID]) async throws -> UUID {
        let snapshot = DiaryContentSnapshot(
            body: body, entryDateWireString: BirthdayFormat.wireString(from: entryDate), childIDs: Set(childIDs)
        )
        if let createdDiaryID {
            if createdDiarySnapshot != snapshot {
                try await diaryAPIClient.updateDiaryEntry(
                    diaryID: createdDiaryID, body: body, entryDate: entryDate, childIDs: childIDs
                )
                createdDiarySnapshot = snapshot
            }
            return createdDiaryID
        }
        let diaryID = try await diaryAPIClient.createDiaryEntry(
            familyID: familyID, body: body, entryDate: entryDate, childIDs: childIDs
        )
        createdDiaryID = diaryID
        createdDiarySnapshot = snapshot
        return diaryID
    }

    /// 依佇列順序逐張上傳（刻意序列、不平行：20 張上限下平行上傳省下的時間有限，序列化換來
    /// 「失敗時只有一張正在傳、容易對應到是哪一張」的除錯簡單性，見 handoff／merge-review R1
    /// m2 已知取捨）。已經上傳成功過的草稿（`uploadedMediaByDraftID` 有記錄）直接沿用舊 id、
    /// 不重傳（M2）。影片超過 60 秒先用 `VideoTrimmer` 裁切壓縮，回傳的暫存檔才是真正拿去
    /// 上傳的那份；上傳成功後清掉本機暫存檔（merge-review R1 m9：先前上傳完全不清，選幾支
    /// 影片試玩幾次就會在 tmp 目錄累積數百 MB）。
    private func uploadAllMedia() async throws -> [UUID] {
        var mediaIDs: [UUID] = []
        for draft in photos {
            if let existing = uploadedMediaByDraftID[draft.id] {
                mediaIDs.append(existing)
                continue
            }
            let id = try await uploadSingle(draft)
            uploadedMediaByDraftID[draft.id] = id
            mediaIDs.append(id)
        }
        return mediaIDs
    }

    private func uploadSingle(_ draft: DiaryPhotoDraft) async throws -> UUID {
        switch draft.kind {
        case .photo(let data, let fileExtension):
            return try await mediaUploadService.uploadPhoto(
                familyID: familyID, data: data, fileExtension: fileExtension, pixelSize: draft.pixelSize
            )
        case .video(let fileURL, let fileExtension, let duration):
            let source = try await VideoTrimmer.trimmedIfNeeded(
                fileURL: fileURL, fileExtension: fileExtension, duration: duration
            )
            // merge-review R1 m7：裁切過的話用輸出的實際像素尺寸；未裁切則沿用草稿原本量到的。
            let id = try await mediaUploadService.uploadVideo(
                familyID: familyID, fileURL: source.fileURL, fileExtension: source.fileExtension,
                pixelSize: source.pixelSize ?? draft.pixelSize
            )
            Self.cleanupVideoTempFiles(originalURL: fileURL, uploadedURL: source.fileURL)
            return id
        }
    }

    /// best-effort：清不掉不影響上傳結果，本來就是暫存檔衛生問題（merge-review R1 m9）。
    private static func cleanupVideoTempFiles(originalURL: URL, uploadedURL: URL) {
        try? FileManager.default.removeItem(at: originalURL)
        if uploadedURL != originalURL {
            try? FileManager.default.removeItem(at: uploadedURL)
        }
    }
}
