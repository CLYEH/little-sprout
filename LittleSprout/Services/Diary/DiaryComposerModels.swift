import UIKit

/// 像素尺寸——`media.width`／`media.height`（`NOT NULL`）需要的原始像素值，跟裝置點數
/// （`CGSize` 慣例代表的 pt）無關，獨立型別避免跟其他地方的 `CGSize` 混用（也讓
/// `DiaryPhotoDraft`／`addPhoto`／`addVideo` 少一個參數，見 SwiftLint
/// `function_parameter_count`）。
struct PixelSize: Equatable {
    let width: Int
    let height: Int
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
