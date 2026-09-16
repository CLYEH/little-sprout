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
/// `fetchAssets` 三支 API 收在一個型別裡，方便呼叫端（`AlbumDetailView+Actions`／
/// `TimelineView+Import`）不用直接碰 Photos framework 型別。
enum PhotoLibraryAccessService {
    /// 讀權限（不彈系統對話框）。
    @MainActor
    static func currentState() -> PhotoLibraryAccessState {
        state(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

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

    /// PHPicker 選取結果 → 分組用的 `ImportDateGrouping.PickedAsset`——依 `itemIdentifier`
    /// 反查 `PHAsset.creationDate`；`.limited` 授權下若某個 identifier 不在目前的存取範圍內
    /// （或任何原因查不到），`fetchAssets` 對那一筆就是查無結果，這裡讓它退化成
    /// `creationDate: nil`（落入「日期不明」群，可改日期）而不是整批失敗——同一批裡有查得到
    /// 跟查不到的混合是預期情況，不是錯誤態。
    static func pickedAssets(for items: [PhotosPickerItem]) -> [ImportDateGrouping.PickedAsset] {
        let identifiers = items.compactMap(\.itemIdentifier)
        guard !identifiers.isEmpty else {
            return items.map { .init(localIdentifier: $0.itemIdentifier ?? UUID().uuidString, creationDate: nil) }
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var creationDateByID: [String: Date] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            creationDateByID[asset.localIdentifier] = asset.creationDate
        }
        return items.map { item in
            let id = item.itemIdentifier ?? UUID().uuidString
            return .init(localIdentifier: id, creationDate: creationDateByID[id])
        }
    }
}
