import AVFoundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// LS-303 R3（merge-review R2 M2，orchestrator 裁決）：`ImportUploadCoordinator` 的過渡實作
/// ——2/2（`ImportPlan` 進度／摘要／完整上傳體驗，blockedBy 本票）落地之前，讓「加入照片」在
/// 本票併入 development 後仍然真的能把照片存進相簿，不是只把整理頁關掉什麼都不做。
///
/// 把 `startImport(plan:)` 收到的每一個未略過群，逐張交給既有「加入照片」單張即傳所走的
/// `UploadQueueStore` 路徑（`AlbumDetailView+Actions.makeUploadQueueStore`／
/// `AlbumsStore.attachUploadedMedia` 同一套）——差別只在來源不是 `PhotosPickerItem`
/// （`PickedItemLoader.load`），而是 `PHAsset.localIdentifier`（`ImportPlan.Group
/// .assetLocalIdentifiers`），需要自己用 `PHImageManager`／`PHAssetResourceManager` 讀出原始
/// 位元組，其餘（副檔名白名單、縮圖下採樣、像素尺寸換算）重用 `PickedItemLoader` 已有的純
/// 函式。
///
/// **限制（刻意，LS-304 上線即拿掉）**：`requiresAlbumSelection == true`——這條過渡管線只支援
/// 「每群都指定相簿」（`UploadQueueStore.onUploadSucceeded` 需要一個確定的 `albumID` 才能呼叫
/// `attachUploadedMedia`），`ImportOrganizeView.ctaBar` 讀這個旗標在使用者選「不放相簿」時
/// 停用主鈕＋提示「本版需先選相簿」，不會走到這裡處理 `albumID == nil` 的情況。
///
/// **生命週期**：本身是 `@MainActor final class`（參照型別），由呼叫端（`AlbumDetailView`）用
/// `@State` 持有、與 `detailStore` 同壽命——`activeQueues` 陣列在整支實例存活期間持續累積、
/// 不主動釋放（過渡版不做精細的佇列回收，同 `AlbumDetailView.uploadQueueStore` 既有的「只建立
/// 一次、往後重用」慣例，但這裡改成「每次匯入各自一份 `UploadQueueStore`」而非重用同一份——
/// 每群相簿可能不同，`onUploadSucceeded` 需要各自捕捉各自的 `albumID`，共用一份反而要另外
/// 想辦法讓同一個 store 內的不同 entry 掛到不同相簿，得不償失）。`startImport` 內建立的
/// `Task { ... }` 沒有 `[weak self]`——刻意讓它強引用 `self`，讓這個 coordinator 實例的存活
/// 不完全依賴呼叫端是否還留著參照，避免使用者在讀取／上傳飛行中恰好觸發 `AlbumDetailView.body`
/// 重新求值、`.importBatchFlow(...)` 傳入新的 coordinator 值把舊的換掉時，讀取到一半的任務被
/// 提早釋放（同 R2 M6 那類 stale-state 臭蟲的預防思路，但這裡用「強引用到任務完成」而非
/// `.fullScreenCover(item:)` 那種寫法解決，因為 coordinator 本身不是 View／狀態綁定）。
@MainActor
final class LegacyAlbumUploadImportCoordinator: ImportUploadCoordinator {
    private let familyID: UUID
    private let mediaUploadService: MediaUploadService
    private let albumsStore: AlbumsStore
    private var activeQueues: [UploadQueueStore] = []

    var requiresAlbumSelection: Bool { true }

    init(familyID: UUID, mediaUploadService: MediaUploadService, albumsStore: AlbumsStore) {
        self.familyID = familyID
        self.mediaUploadService = mediaUploadService
        self.albumsStore = albumsStore
    }

    func startImport(plan: ImportPlan) {
        for group in plan.groups where !group.isSkipped && !group.assetLocalIdentifiers.isEmpty {
            // `requiresAlbumSelection == true` 讓 `ImportOrganizeView.ctaBar` 在按下主鈕前
            // 就擋掉「有未略過群沒有 albumID」的情況——這裡再擋一層不信任呼叫端，跳過而非崩潰。
            guard let albumID = group.albumID else { continue }
            enqueue(assetLocalIdentifiers: group.assetLocalIdentifiers, albumID: albumID)
        }
    }

    private func enqueue(assetLocalIdentifiers: [String], albumID: UUID) {
        let familyID = familyID
        let albumsStore = albumsStore
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaUploadService,
            onUploadSucceeded: { _, mediaID in
                Task {
                    await albumsStore.attachUploadedMedia(albumID: albumID, familyID: familyID, mediaID: mediaID)
                }
            }
        )
        activeQueues.append(store)
        Task {
            let uploads = await Self.loadPendingUploads(for: assetLocalIdentifiers)
            store.enqueue(uploads)
        }
    }

    // MARK: - PHAsset → PendingUpload（M5 同思路：Photos 資料庫查詢離開 MainActor）

    private static func loadPendingUploads(for identifiers: [String]) async -> [PendingUpload] {
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
        let thumbnail = await PickedItemLoader.downsizedThumbnail(for: image)
        return PendingUpload(
            kind: .photo(data: result.data, fileExtension: ext), thumbnail: thumbnail, pixelSize: pixelSize
        )
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
        let thumbnail = PickedItemLoader.firstFrame(of: avAsset)
        return PendingUpload(
            kind: .video(fileURL: destination, fileExtension: ext), thumbnail: thumbnail, pixelSize: pixelSize
        )
    }
}
