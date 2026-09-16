import AVFoundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// LS-303 R3（merge-review R2 M2，orchestrator 裁決）：`ImportUploadCoordinator` 的過渡實作
/// ——2/2（`ImportPlan` 進度／摘要／完整上傳體驗，blockedBy 本票）落地之前，讓「加入照片」在
/// 本票併入 development 後仍然真的能把照片存進相簿，不是只把整理頁關掉什麼都不做。
///
/// 把 `startImport(plan:)` 收到的每一個未略過群，逐張交給既有「加入照片」單張即傳所走的
/// `UploadQueueStore` 路徑（`AlbumDetailView+Actions.loadPicked`／`AlbumsStore
/// .attachUploadedMedia` 同一套）——差別只在來源不是 `PhotosPickerItem`
/// （`PickedItemLoader.load`），而是 `PHAsset.localIdentifier`（`ImportPlan.Group
/// .assetLocalIdentifiers`），需要自己用 `PHImageManager`／`PHAssetResourceManager` 讀出原始
/// 位元組，其餘（副檔名白名單、縮圖下採樣、像素尺寸換算）重用 `PickedItemLoader` 已有的純
/// 函式。
///
/// **限制（刻意，LS-304 上線即拿掉）**：`requiresAlbumSelection == true`——這條過渡管線只支援
/// 「每群都指定相簿」（`onUploadSucceeded` 需要一個確定的 `albumID` 才能呼叫
/// `attachUploadedMedia`）。R4 起這不再是「主鈕 disabled」——`ImportOrganizeView.ctaBar` 按下
/// 時若偵測到有未略過群沒有 `albumID`，走回話列提醒＋停留整理頁，不進這支 coordinator（品牌
/// 「不可協商」第 8 條：驗證型 disable＝0，見 merge-review R3 M3）。
///
/// **生命週期／併發上限（LS-303 R4，merge-review R3 M1／M2 修正）**：R3 版本對每個日期群各
/// `new` 一份 `UploadQueueStore`、由這支 coordinator 自己的 `activeQueues` 陣列持有——兩個
/// 問題：(1) `UploadQueueStore` 的 `maxConcurrentUploads`／影片 export 名額都是**實例級**
/// 旗標，拆成多份等於併發上限被乘以群數；(2) coordinator 本身是 `AlbumDetailView` 的
/// `@State`，使用者在讀取位元組期間離開畫面會讓 coordinator（與它持有的 store）一起被釋放，
/// 尚未開始執行的上傳 Task 全部 silently return。R4 改成呼叫 `albumsStore
/// .sharedUploadQueueStore(...)` 拿 app 層級單一實例（與「加入照片」單張即傳共用同一份），
/// 兩個問題一併解決——這支 coordinator 本身不再持有任何 store，`startImport` 內的 `Task`
/// 只是「讀位元組＋登記 entry→albumID＋enqueue」這三步的容器，做完就結束，不需要刻意強引用
/// `self` 撐著誰的生命週期（上一版檔頭文件註解宣稱的「刻意讓 Task 強引用 self」與程式碼實際
/// 從未捕捉 `self` 不符，這裡一併訂正，見 merge-review R3 i4）。
///
/// **可注入的 asset 讀取掛鉤**：`loadPendingUploads` 預設呼叫 `Self
/// .loadPendingUploadsFromPhotoLibrary`（真正的 `PHImageManager`／`PHAssetResourceManager`
/// 呼叫），測試可換成假值——`PHAsset` 無法在單元測試合成假值（同 `PhotosPickerItem` 既有
/// 理由），這個縫隙讓 `startImport` 的群迭代／略過／`albumID == nil` 跳過邏輯，以及「呼叫端
/// 釋放後入列項仍完成」這個 M2 修法本身，都能在不碰真實 Photos 資料庫的情況下被覆蓋（見
/// `LegacyAlbumUploadImportCoordinatorTests`）。
@MainActor
final class LegacyAlbumUploadImportCoordinator: ImportUploadCoordinator {
    private let familyID: UUID
    private let mediaUploadService: MediaUploadService
    private let albumsStore: AlbumsStore
    private let loadPendingUploads: @Sendable ([String]) async -> [PendingUpload]

    var requiresAlbumSelection: Bool { true }

    init(
        familyID: UUID, mediaUploadService: MediaUploadService, albumsStore: AlbumsStore,
        loadPendingUploads: @escaping @Sendable ([String]) async -> [PendingUpload] =
            LegacyAlbumUploadImportCoordinator.loadPendingUploadsFromPhotoLibrary
    ) {
        self.familyID = familyID
        self.mediaUploadService = mediaUploadService
        self.albumsStore = albumsStore
        self.loadPendingUploads = loadPendingUploads
    }

    func startImport(plan: ImportPlan) {
        let store = albumsStore.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaUploadService)
        for group in plan.groups where !group.isSkipped && !group.assetLocalIdentifiers.isEmpty {
            // `requiresAlbumSelection == true` 讓 `ImportOrganizeView.ctaBar` 在按下主鈕前
            // 就擋掉「有未略過群沒有 albumID」的情況——這裡再擋一層不信任呼叫端，跳過而非崩潰。
            guard let albumID = group.albumID else { continue }
            enqueue(assetLocalIdentifiers: group.assetLocalIdentifiers, albumID: albumID, into: store)
        }
    }

    private func enqueue(assetLocalIdentifiers: [String], albumID: UUID, into store: UploadQueueStore) {
        let loadPendingUploads = loadPendingUploads
        let albumsStore = albumsStore
        Task {
            let uploads = await loadPendingUploads(assetLocalIdentifiers)
            for upload in uploads {
                albumsStore.registerPendingAlbum(entryID: upload.id, albumID: albumID)
            }
            store.enqueue(uploads)
        }
    }

    // MARK: - PHAsset → PendingUpload（M5 同思路：Photos 資料庫查詢離開 MainActor）

    nonisolated static func loadPendingUploadsFromPhotoLibrary(for identifiers: [String]) async -> [PendingUpload] {
        let assets = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
            return assets
        }.value
        var uploads: [PendingUpload] = []
        for asset in assets {
            if let upload = await loadPendingUpload(for: asset) {
                uploads.append(upload)
            }
        }
        return uploads
    }

    private static func loadPendingUpload(for asset: PHAsset) async -> PendingUpload? {
        switch asset.mediaType {
        case .image: await loadPhotoUpload(for: asset)
        case .video: await loadVideoUpload(for: asset)
        default: nil
        }
    }

    private static func loadPhotoUpload(for asset: PHAsset) async -> PendingUpload? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let result: (data: Data, dataUTI: String?)? = await withCheckedContinuation { continuation in
            let manager = PHImageManager.default()
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, dataUTI))
            }
        }
        guard let result else { return nil }
        let ext = (result.dataUTI.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg").lowercased()
        guard PickedItemLoader.isSupportedExtension(ext, isVideo: false),
              let image = UIImage(data: result.data),
              let pixelSize = PickedItemLoader.orientedPixelSize(of: image)
        else { return nil }
        // LS-303 R5（merge-review R4 M2）：這條過渡管線沒有任何畫面顯示縮圖（不開
        // `UploadQueueSheetView`）——共用佇列 entry 現在活到登出（見 `AlbumsStore
        // +SharedUploadQueue.swift` 檔頭文件註解），200 張批次若都解一份縮圖會在 session
        // 期間白白留著約 66 MB；`nil` 讓呼叫端退回系統圖示佔位，同時省掉這裡的解碼成本。
        return PendingUpload(kind: .photo(data: result.data, fileExtension: ext), thumbnail: nil, pixelSize: pixelSize)
    }

    private static func loadVideoUpload(for asset: PHAsset) async -> PendingUpload? {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video || $0.type == .fullSizeVideo })
        else { return nil }
        let rawExtension = (resource.originalFilename as NSString).pathExtension.lowercased()
        let ext = rawExtension.isEmpty ? "mov" : rawExtension
        guard PickedItemLoader.isSupportedExtension(ext, isVideo: true),
              let destination = try? MediaDraftTempStorage.newFileURL(extension: ext)
        else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let succeeded: Bool = await withCheckedContinuation { continuation in
            let manager = PHAssetResourceManager.default()
            manager.writeData(for: resource, toFile: destination, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard succeeded else { return nil }
        let avAsset = AVURLAsset(url: destination)
        guard let pixelSize = await VideoTrimmer.pixelSize(ofFirstVideoTrackIn: avAsset) else { return nil }
        // LS-303 R5（merge-review R4 M2）：同上方 `loadPhotoUpload`——這條過渡管線不顯示縮圖。
        return PendingUpload(
            kind: .video(fileURL: destination, fileExtension: ext), thumbnail: nil, pixelSize: pixelSize
        )
    }
}
