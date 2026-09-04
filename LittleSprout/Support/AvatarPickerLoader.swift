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

/// LS-173：把 `CreateChildView+Avatar.swift`／`EditChildView.swift` 的 `loadPickedAvatar()`
/// 原本各自複製一份的世代守門邏輯抽出來——兩份原本逐字相同：`avatarLoadGeneration += 1` →
/// 呼叫 `AvatarPickerLoader.load` → 成功／非取消錯誤都要先確認自己仍是最新世代才寫
/// `@State`、`CancellationError` 一律靜默、`defer` 收 loading 指示的判斷同樣看世代。
///
/// 收在讀取實際位元組的 `operation` 閉包，不是直接收 `PhotosPickerItem`：真實
/// `PhotosPickerItem` 沒辦法在單元測試裡構造出假的、控制時序（同本檔 `PickedItemLoader`
/// 檔頭註解「自陳不可單元測試」的既有理由——見 `Services/Diary/PickedItemLoader.swift`），
/// 世代守門這段純邏輯才是這裡真正要驗的東西；呼叫端傳
/// `{ try await AvatarPickerLoader.load(item) }` 進來。
///
/// `@MainActor`：呼叫端（View 的 `loadPickedAvatar()`）本身已經是 MainActor 隔離（`View`
/// 協定的 `body` 要求推導整個型別），`generation` 只被 MainActor 讀寫，不需要額外同步。
///
/// merge-review R1 i2（`8b477108`）：`load(operation:)` 把「記世代」與「呼叫 `operation`」
/// 包在同一個同步方法呼叫裡，呼叫端在 `await` 這個方法之前寫的 `@State`（`isLoadingAvatar`／
/// `avatarLoadErrorMessage`）才不會被舊 task 插隊——這個安全性**前提是本型別維持
/// `@MainActor final class`**：呼叫端與這裡同一個 actor，`await coordinator.load` 不會真的
/// suspend／換 executor，`generation += 1` 因此保證在呼叫端那兩行 `@State` 寫入「之後」但
/// 中間沒有其他 MainActor 工作插得進來。**若改成 `actor`**，`await` 會變成真的跨 actor 呼叫、
/// 出現一個舊 task 可插入的窗口——屆時要把「世代 +1」改回同步、由呼叫端在自己的 `await` 之前
/// 先呼叫（結構上等同原本 R3 的順序），不能只是加鎖。
@MainActor
final class AvatarLoadCoordinator {
    private var generation = 0

    /// 載入失敗時顯示的文案——與原本兩個 View 各自寫死的字串逐字相同。
    static let loadFailureMessage = "這張照片沒辦法使用，請換一張試試。"

    typealias Loaded = AvatarPickerLoader.Loaded

    enum Outcome {
        case applied(data: Data, previewImage: UIImage)
        /// 被下一次選取取消（`CancellationError`），或雖然完成／失敗但世代已落後——兩者
        /// 呼叫端都「什麼都不寫」，差別只在 `isCurrent`（給載入指示用），呼叫端不需要區分。
        case discarded
        case failed(message: String)
    }

    /// merge-review R1 i4（`8b477108`）：原本叫 `Result`，會在本型別內遮蔽 stdlib
    /// `Swift.Result`——雖然目前無害（本型別內沒用到 `Swift.Result`），改名避免日後混淆。
    struct LoadResult {
        let outcome: Outcome
        /// 同原本 `defer { if generation == avatarLoadGeneration { isLoadingAvatar = false } }`
        /// 的判斷——不管走哪個分支都要看世代，這裡跟結果一起回傳，呼叫端不用再自己比一次。
        let isCurrent: Bool
    }

    /// 世代守門本體：先把自己的呼叫記成最新世代，`operation` 完成（或被取消／失敗）後只有
    /// 「仍是最新世代」的結果才分類成會被寫進 `@State` 的 `.applied`／`.failed`。
    func load(operation: () async throws -> Loaded) async -> LoadResult {
        generation += 1
        let myGeneration = generation
        do {
            let loaded = try await operation()
            let isCurrent = myGeneration == generation
            return LoadResult(
                outcome: isCurrent ? .applied(data: loaded.data, previewImage: loaded.previewImage) : .discarded,
                isCurrent: isCurrent
            )
        } catch is CancellationError {
            return LoadResult(outcome: .discarded, isCurrent: myGeneration == generation)
        } catch {
            let isCurrent = myGeneration == generation
            return LoadResult(
                outcome: isCurrent ? .failed(message: Self.loadFailureMessage) : .discarded,
                isCurrent: isCurrent
            )
        }
    }
}
