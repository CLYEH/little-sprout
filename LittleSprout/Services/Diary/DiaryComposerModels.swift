import UIKit

/// 像素尺寸——`media.width`／`media.height`（`NOT NULL`）需要的原始像素值，跟裝置點數
/// （`CGSize` 慣例代表的 pt）無關，獨立型別避免跟其他地方的 `CGSize` 混用（也讓
/// `DiaryPhotoDraft`／`addPhoto`／`addVideo` 少一個參數，見 SwiftLint
/// `function_parameter_count`）。
struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

/// 佇列縮圖的版面常數——`DiaryEditorView+Photos.swift`（縮圖 `frame`）、`PickedItemLoader`
/// （縮圖產生時的目標像素預算）、`DiaryPhotoReorderMath`（拖曳落點換算的格距）三處共用同一個
/// 值，避免各自硬寫字面值、改一處忘了改另一處時安靜地量錯（merge-review R1 m12）。
enum DiaryPhotoQueueLayout {
    /// 縮圖顯示尺寸（pt），佇列裡的照片／影片格與「新增照片」cell 共用。
    static let thumbnailSize: CGFloat = 96
    /// 縮圖產生時的目標像素邊長——3× 顯示尺寸，涵蓋 3x Retina 螢幕不失真，遠低於原圖解析度
    /// （merge-review R1 M4：`previewImage` 不該是全解析度原圖）。
    static let thumbnailPixelBudget: CGFloat = thumbnailSize * 3
}

/// Storage 413（payload too large）映射出來的 `AppError.code`——client 自己合成的 sentinel，
/// **不是**後端 SQLSTATE／`LSErrorCode`（`AppError.swift` 檔頭契約：`code` 保留給「後端原始
/// 錯誤碼」）。刻意用 `client_` 前綴宣告這個區別：`error-codes-check.sh` 的三方對帳只掃
/// `LS[0-9]{3}` 形狀的碼，這個字面值不會被誤認成漏登記的後端自訂碼（merge-review R1 m3）。
enum DiaryMediaErrorCode {
    static let payloadTooLarge = "client_storage_413"
}

/// 12c 失敗態螢幕上實際顯示的文案——依 `AppError.code` 分流（同 `JoinCodePhase.swift` 對
/// `LSErrorCode.inviteCodeExpired`／`inviteCodeExhausted` 的既有慣例）。抽成獨立、跟
/// SwiftUI 脫鉤的純函式（不是留在 `DiaryEditorView+ActionBar.swift` 裡的 private 方法），
/// 才能被單元測試直接釘住「螢幕上出現的字」——`AppError.userFacingMessage` 忽略
/// associated value，光測到 `AppError` 本身測不出這個問題（merge-review R1 M1／I4：先前
/// 測試只驗到 `message.contains("50MB")`，但那是 log 用的 `message` 欄位，從未出現在畫面上）。
enum DiaryPublishErrorMessage {
    static func displayText(for error: AppError) -> String {
        if case .validationRetryable(_, let code) = error, code == DiaryMediaErrorCode.payloadTooLarge {
            return "檔案超過 50MB 上限，請選擇較小的照片或影片再試一次。"
        }
        return error.userFacingMessage
    }
}

/// 日記編輯器照片佇列裡的一格草稿（尚未上傳）。`id` 是本機穩定識別碼，用來驅動選取／拖曳排序
/// ／VoiceOver 自訂動作（`design/littlesprout.pen` Handoff Notes `v0tLp`：`Set<PhotoID>`）。
struct DiaryPhotoDraft: Identifiable, Equatable {
    enum Kind: Equatable {
        case photo(data: Data, fileExtension: String)
        case video(fileURL: URL, fileExtension: String, duration: TimeInterval)
    }

    let id: UUID
    let kind: Kind
    /// 縮圖佇列顯示用；來源解碼失敗時允許是 nil（極端情況，UI 用系統圖示佔位）。
    let previewImage: UIImage?
    let pixelSize: PixelSize

    init(id: UUID = UUID(), kind: Kind, previewImage: UIImage?, pixelSize: PixelSize) {
        self.id = id
        self.kind = kind
        self.previewImage = previewImage
        self.pixelSize = pixelSize
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }

    var videoDuration: TimeInterval? {
        if case .video(_, _, let duration) = kind { return duration }
        return nil
    }

    /// R6 補的第④前提（`v0tLp`）：影片超過 60 秒只提示、不阻擋——這支旗標驅動 12g 那行
    /// 「這支影片 M:SS，發佈時會保留前 60 秒」回話列。
    var exceedsPublishDuration: Bool {
        guard let videoDuration else { return false }
        return DiaryDurationFormat.exceedsMaxPublishDuration(videoDuration)
    }
}

/// 送出（`create_diary_entry`）進行中的狀態機——同 `ChildOperationState` 的角色，但多一個
/// `.uploading` 態區分「正在傳照片」與「照片傳完、正在寫 RPC」，兩者在 UI 上共用同一顆
/// `cmp/Button Working`（12b），差異只在文案（見 `DiaryEditorView`）。
enum DiaryPublishState: Equatable {
    case idle
    case uploading
    case success
    case failure(AppError)

    var isInFlight: Bool { self == .uploading }
}

/// 送出結果：`.capacityReached` 讓呼叫端知道「這張沒有真的被加進佇列」，但**不**是錯誤
/// ——佇列已滿時的回話（「最多 20 張，想放更多可以建相簿」）本來就常駐顯示，呼叫端不需要
/// 額外彈窗（十條之八：不因為「這次沒生效」就跳出額外的懲罰性 UI）。
enum DiaryPhotoAddOutcome: Equatable {
    case added
    case capacityReached
}

/// `DiaryComposerStore.resolveDiaryID` 的 memoized 分支比對用——`childIDs` 特意存成 `Set`
/// 而不是 `[UUID]`：`selectedChildIDs` 本身就是集合，兩次呼叫之間即使集合內容相同，`Array(
/// selectedChildIDs)` 的走訪順序也不保證一致，用陣列比較會有假陰性（誤判成「內容變了」，
/// 白白多打一次 `update_diary_entry`）（merge-review R2 N1）。`entryDate` 存的是
/// `BirthdayFormat.wireString(from:)` 算出來的字串、不是原始 `Date`（merge-review R3 q2）：
/// `SupabaseDiaryAPIClient` 送出去的本來就只有年月日（`entryDate: BirthdayFormat.wireString
/// (from: entryDate)`），比對全精度的 `Date` 會比實際送出的內容更嚴格——`DatePicker
/// (displayedComponents: .date)` 目前產不出「同一天、不同時刻」的兩個值，所以今天不會誤判，
/// 但比對範圍精準對齊「真正送出去的東西」，不留下未來漂移的空間。
struct DiaryContentSnapshot: Equatable {
    let body: String
    let entryDateWireString: String
    let childIDs: Set<UUID>
}
