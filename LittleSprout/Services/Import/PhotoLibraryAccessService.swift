import Photos
import PhotosUI
import SwiftUI

/// 相機膠卷批次匯入需要的相片庫存取狀態（LS-303 範圍 4：權限態 06a／06b）。
///
/// `.photosPicker`（`PHPickerViewController`）本身不需要任何授權就能挑選照片——這是它的
/// 設計重點。但本票要依 EXIF 拍攝日期分組，需要用 `PHAsset.localIdentifier` 反查
/// `creationDate`（`PHAsset.fetchAssets(withLocalIdentifiers:)`），這一步才需要
/// `PHPhotoLibrary` 授權；`.limited`／`.denied` 因此不是擋在「能不能挑照片」，而是擋在
/// 「挑完之後拿不拿得到完整的 EXIF 分組資料」——所以入口動作先請求授權，狀態決定往下走
/// 整理頁（`.authorized`／`.limited`，`.limited` 疊一張提醒 banner）還是空狀態（`.denied`）。
enum PhotoLibraryAccessState: Equatable {
    case authorized
    case limited
    case denied
}

/// 對 `PHPhotoLibrary` 的最小包裝——把 `PHAuthorizationStatus`／`requestAuthorization`／
/// `fetchAssets` 三支 API 收在一個型別裡，方便呼叫端（`ImportBatchFlowModifier`）不用
/// 直接碰 Photos framework 型別。
enum PhotoLibraryAccessService {
    /// 尚未決定時彈系統對話框；已決定過的狀態直接回傳，不會重複彈窗（系統行為）。
    @MainActor
    static func requestAccess() async -> PhotoLibraryAccessState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return state(for: status)
    }

    private static func state(for status: PHAuthorizationStatus) -> PhotoLibraryAccessState {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined, .restricted, .denied: .denied
        @unknown default: .denied
        }
    }

    /// `pickedAssetsResult(for:)` 的回傳值。
    struct PickedAssetsResult {
        let pickedAssets: [ImportDateGrouping.PickedAsset]
        /// localIdentifier → `PHAsset`——供 `ImportThumbnailProvider` 要縮圖用，只含
        /// `fetchAssets` 真的查得到的那些（`.limited` 範圍外或已刪除的照片不在裡面）。
        let assetsByID: [String: PHAsset]
        /// merge-review R1 i3：`itemIdentifier` 缺失（理論上極罕見，PHPicker 正常挑選一定
        /// 帶）的筆數——整筆捨棄，不塞假 id 進 `pickedAssets`，呼叫端可用這個數字提示使用者
        /// 「有幾個項目沒有加入」。
        let droppedCount: Int
    }

    /// 步驟一（MainActor，呼叫端在 `.onChange(of: pickerSelection)` 裡同步呼叫）：
    /// `PhotosPickerItem.itemIdentifier` 是輕量同步屬性存取，不是 Photos 資料庫查詢——
    /// 留在 MainActor 讀；`PhotosPickerItem` 本身不跨過 `Task.detached` 邊界（避免任何
    /// 對它非 MainActor 存取的未定義行為）。只做「讀出 `itemIdentifier`」這一步，分類邏輯
    /// 交給 `partition(identifiers:)`（merge-review R2 M3：`PhotosPickerItem` 本身無法在
    /// 單元測試建構假值，抽成這樣才能被覆蓋，同 `PickedItemLoader` 檔頭既有的拆分理由）。
    @MainActor
    static func identifiers(for items: [PhotosPickerItem]) -> (identifiers: [String], droppedCount: Int) {
        partition(identifiers: items.map(\.itemIdentifier))
    }

    /// 「一批 `itemIdentifier?`（`nil` 代表 PHPicker 沒有帶 photo library 建立、或極罕見的
    /// 讀取失敗）→ 保留原始順序的非 nil identifier 列表＋捨棄筆數」——純函式，跟
    /// `PhotosPickerItem` 完全脫鉤，可以直接餵假 identifier 陣列做單元測試（merge-review R2
    /// M3 B1 修復：見 `PhotoLibraryAccessServiceTests`）。
    static func partition(identifiers: [String?]) -> (identifiers: [String], droppedCount: Int) {
        let ids = identifiers.compactMap { $0 }
        return (ids, identifiers.count - ids.count)
    }

    /// 步驟二（merge-review R1 M5，呼叫端包 `Task.detached` 離開 MainActor）：真正的
    /// Photos 資料庫查詢——`PHAsset.fetchAssets`／`enumerateObjects` 是同步、會卡住呼叫
    /// 執行緒的操作，這支函式本身仍是同步純函式（方便單元測試不必牽扯 `Task`），只吃／
    /// 回傳 `String`／`PickedAssetsResult`（皆為 value type，跨 actor 邊界安全），不碰
    /// `PhotosPickerItem`。
    ///
    /// `.limited` 授權下若某個 identifier 不在目前的存取範圍內（或任何原因查不到），
    /// `fetchAssets` 對那一筆就是查無結果，這裡讓它退化成 `creationDate: nil`（落入「日期
    /// 不明」群，可改日期）而不是整批失敗——同一批裡有查得到跟查不到的混合是預期情況，
    /// 不是錯誤態；這跟「沒有 `itemIdentifier`」（`droppedCount`）是兩回事，不要混在一起。
    static func fetchResult(for identifiers: [String], droppedCount: Int) -> PickedAssetsResult {
        var assetsByID: [String: PHAsset] = [:]
        if !identifiers.isEmpty {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }
        }
        let pickedAssets = identifiers.map { id in
            ImportDateGrouping.PickedAsset(localIdentifier: id, creationDate: assetsByID[id]?.creationDate)
        }
        return PickedAssetsResult(pickedAssets: pickedAssets, assetsByID: assetsByID, droppedCount: droppedCount)
    }
}
