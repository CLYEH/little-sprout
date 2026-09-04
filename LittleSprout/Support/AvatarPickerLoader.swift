import PhotosUI
import SwiftUI
import UIKit

/// `PhotosPickerItem` → 頭像預覽需要的原始資料＋降採樣預覽圖（LS-169 R2 M2/M3）。
///
/// 抽成獨立檔案、跟 `CreateChildView`／`EditChildView` 脫鉤：兩個畫面原本各自在
/// `.onChange(of: pickedAvatarItem)` 裡開一個裸 `Task` 讀 `Data`，且畫面的 `pickedAvatarImage`
/// 是計算屬性、每次 `body` 求值就用 `UIImage(data:)` 重新解碼一次**全尺寸**原圖（merge-review
/// R1 M2：打一個字＝body 重算一次＝重新解碼一次）。這裡比照 `PickedItemLoader`
/// （`Services/Diary/PickedItemLoader.swift`，R1 M4 既有慣例）：預覽圖用
/// `UIImage.byPreparingThumbnail(ofSize:)` 降採樣（背景執行、不先解碼整張原圖進記憶體），
/// 呼叫端只需要在載入完成後把結果存進 `@State`，`body` 不再自己解碼。
enum AvatarPickerLoader {
    /// 預覽圖的降採樣目標（point，不是 pixel——`byPreparingThumbnail` 吃 point 尺寸並自動乘上
    /// 螢幕 scale）：頭像預覽最大顯示尺寸是 iPad `regularLayout` 的 504pt，抓 3x scale 上限
    /// 給一點餘裕，遠小於全尺寸原圖。
    private static let previewPointSize = CGSize(width: 520, height: 520)

    struct Loaded {
        /// 完整原始位元組——真正上傳前的裁方／縮圖（`AvatarImageProcessor.squareJPEG`）需要
        /// 原圖細節，不能只吃降採樣後的預覽圖。
        let data: Data
        /// 降採樣後的預覽圖；來源資料看得懂但降採樣本身失敗時退回未降採樣的原圖（同
        /// `PickedItemLoader.downsizedThumbnail` 的既有理由：至少預覽看得到內容）。
        let previewImage: UIImage
    }

    enum LoadError: Error {
        /// `loadTransferable` 失敗，或讀出來的位元組不是圖片。
        case unreadable
    }

    /// 讀取＋降採樣。呼叫端用 `.task(id: item) { … }` 包住（id 改變時 SwiftUI 自動取消前一個
    /// task，畫面消失時也自動取消，比手動保存／取消 `Task` 參照更不容易漏，見
    /// `CreateChildView.avatarField`／`EditChildView.avatarField` 文件註解）——這裡另外在每個
    /// await 之後補一次 `Task.isCancelled` 檢查，防的是「已經 cancel 但 await 那一刻剛好完成」
    /// 的極短窗口（cooperative cancellation 本來就不保證讀完 await 立刻停）。
    static func load(_ item: PhotosPickerItem) async throws -> Loaded {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw LoadError.unreadable
        }
        try Task.checkCancellation()
        guard let image = UIImage(data: data) else {
            throw LoadError.unreadable
        }
        try Task.checkCancellation()
        let preview = await image.byPreparingThumbnail(ofSize: previewPointSize) ?? image
        return Loaded(data: data, previewImage: preview)
    }
}
