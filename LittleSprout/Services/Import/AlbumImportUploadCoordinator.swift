import AVFoundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// LS-304：`ImportUploadCoordinator` 的正式實作——取代 LS-303 R3 的過渡管線
/// （`LegacyAlbumUploadImportCoordinator`，本票移除）。把 `startImport(plan:)` 收到的每一個
/// 未略過群，展開成 `UploadQueueStore`（`AlbumsStore.sharedUploadQueueStore`，同「加入照片」
/// 單張即傳共用同一份實例，理由見 `AlbumsStore+SharedUploadQueue.swift` 檔頭文件註解）能吃
/// 的 `PendingUpload`：
///
/// - **`taken_at`**（票文範圍 1）：每群的 `anchorDate`（已知日期群＝EXIF 分組日；日期不明群
///   ＝使用者可改的推測值）直接當這一群所有項目的 `taken_at`——`ImportDateGrouping.group(_:)`
///   把個別 asset 的 `creationDate` 收斂成群級 `anchorDate` 之後，個別 asset 的原始時刻就不
///   在 `ImportPlan` 裡了（見該檔文件註解），這是目前資料流下唯一還留著、且已經是「EXIF 日
///   或使用者覆寫」語意的值。
/// - **HEIC→JPEG**（票文範圍 2，C2a）：`ImportMediaTranscoder.convertHEICToJPEG`。
/// - **影片 >1 分鐘**：不在這裡處理——`UploadQueueStore.performUpload` 已經對每一支影片呼叫
///   `VideoTrimmer.compressedForUpload`（裁到 60 秒內，LS-279 既有規則），批次匯入的影片與
///   「加入照片」單張即傳走同一條路徑，天然滿足票文「影片最長 1 分鐘…裁切」。
/// - **Live Photo**（票文範圍 2）：`PHAsset.mediaSubtypes.contains(.photoLive)` 時展開成
///   兩筆佇列項目——靜態照片（同一般照片路徑，含 HEIC 轉檔）＋配對短片（`PHAssetResource
///   .type == .pairedVideo`，走一般影片路徑，同樣受 60 秒規則）。**已知限制**：這讓
///   `entryIDs.count` 可能大於 `ImportBatchSession.expectedAssetCount`，見該型別文件註解。
/// - **縮圖**：真的產生（`PickedItemLoader.downsizedThumbnail`／`firstFrame`，同一套下採樣
///   純函式）——04／05 進度／摘要頁的 Queue Row 需要顯示縮圖（LS-142 既有版式），跟已移除
///   的 Legacy 管線（R5 起 `thumbnail: nil`，因為它從未開任何畫面顯示縮圖）不同，這裡是
///   真正的外部呼叫端，`PickedItemLoader.downsizedThumbnail`／`firstFrame` 的 internal 存取
///   層級因此保留（不隨 Legacy 移除收回，檔頭註解已更新指向這裡）。
///
/// **可注入的 asset 讀取掛鉤**：同 Legacy 既有理由——`PHAsset` 無法在單元測試合成假值，
/// `loadPendingUpload` 讓群迭代／略過／`albumID == nil` 跳過這些邏輯能在不碰真實 Photos
/// 資料庫的情況下被覆蓋（見 `AlbumImportUploadCoordinatorTests`）；HEIC 轉檔／Live Photo
/// 展開等「三規則」邏輯則直接對 `ImportMediaTranscoder` 與這支類別自己的靜態轉換函式測試。
///
/// **merge-review R1 M3**：`enqueue(group:...)` 逐 identifier 讀一筆就 `store.enqueue`
/// 一筆（不整群讀完才入列——同一筆原圖 `Data` 不再需要跟同群其餘幾十張同時留在記憶體）；
/// `startImport(plan:)` 用 `withTaskGroup` 把同時處理中的群數上限設在 `maxConcurrentGroupLoads`
/// （沿用 `UploadQueueStore.maxConcurrentUploads` 預設值 3 的既有語彙——上傳端本身也只吃得下
/// 3 筆併發，群讀取端不需要衝更快）。
@MainActor
final class AlbumImportUploadCoordinator: ImportUploadCoordinator {
    /// 沿用 `UploadQueueStore.maxConcurrentUploads` 預設值（見該型別檔頭「並發上限」文件
    /// 註解）——群層級讀取與上傳端共用同一個數字，不是巧合：讀更快也沒有意義，上傳端吃不下。
    private static let maxConcurrentGroupLoads = 3

    private let familyID: UUID
    private let mediaUploadService: MediaUploadService
    private let albumsStore: AlbumsStore
    private let loadPendingUpload: @Sendable (String) async -> [PendingUpload]

    init(
        familyID: UUID, mediaUploadService: MediaUploadService, albumsStore: AlbumsStore,
        loadPendingUpload: @escaping @Sendable (String) async -> [PendingUpload] =
            AlbumImportUploadCoordinator.loadPendingUpload(forIdentifier:)
    ) {
        self.familyID = familyID
        self.mediaUploadService = mediaUploadService
        self.albumsStore = albumsStore
        self.loadPendingUpload = loadPendingUpload
    }

    /// 同步回傳 `ImportBatchSession`——`entryIDs` 隨每一群各自的非同步讀取逐步填入，04 進度
    /// 頁不需要等全部群都讀完才能掛載（見該型別文件註解）。
    func startImport(plan: ImportPlan) -> ImportBatchSession {
        let store = albumsStore.sharedUploadQueueStore(familyID: familyID, mediaUploadService: mediaUploadService)
        let activeGroups = plan.groups.filter { !$0.isSkipped && !$0.assetLocalIdentifiers.isEmpty }
        let session = ImportBatchSession(
            expectedAssetCount: plan.pendingAssetCount, nonSkippedGroupCount: activeGroups.count
        )
        Task { [weak self] in
            await self?.enqueueGroups(activeGroups, into: store, session: session)
        }
        return session
    }

    /// merge-review R1 M3(b)：群層級併發上限——一次最多 `maxConcurrentGroupLoads` 群同時在讀，
    /// 不是 200 張分 20 群時 20 個 `Task` 一次全開（原本的寫法，峰值記憶體等於全部群的原圖
    /// 位元組總和）。標準的「bounded concurrency」`withTaskGroup` 寫法：先塞滿上限，每有一個
    /// 完成就補一個進來，直到來源耗盡。
    ///
    /// merge-review R2 M4：`session.isCancelled` 一旦被 04b 確認取消設為 true，兩個迴圈都不再
    /// 排新的群——原本沒有這道檢查時，還沒排到的群會照樣被讀出、`store.enqueue`、共用佇列
    /// 照常上傳成功並掛進相簿，使用者按了「取消」卻繼續看到照片湧進時間軸（見 handoff M4）。
    private func enqueueGroups(
        _ groups: [ImportPlan.Group], into store: UploadQueueStore, session: ImportBatchSession
    ) async {
        var iterator = groups.makeIterator()
        await withTaskGroup(of: Void.self) { taskGroup in
            for _ in 0..<Self.maxConcurrentGroupLoads {
                guard !session.isCancelled, let group = iterator.next() else { break }
                taskGroup.addTask { [weak self] in await self?.enqueue(group: group, into: store, session: session) }
            }
            while await taskGroup.next() != nil {
                guard !session.isCancelled, let group = iterator.next() else { continue }
                taskGroup.addTask { [weak self] in await self?.enqueue(group: group, into: store, session: session) }
            }
        }
    }

    /// merge-review R1 M1＋M2＋M3(a)：
    /// - M1：`anchorDate` 夾限「不晚於現在」——寫入端雙保險，UI 端另有 `ImportGroupDatePickerSheet`
    ///   的 `DatePicker(in: ...Date())` 擋住未來日期，這裡再擋一層（裝置時鐘、UI 之外的呼叫路徑）。
    /// - M2：逐 identifier 讀，讀不到／不支援格式／轉檔失敗（回傳空陣列）計入 `droppedCount`，
    ///   不靜默丟——`markGroupResolved(droppedCount:)` 累加進 `session.droppedCount`。
    /// - M3(a)：讀到一筆立刻 `store.enqueue`，不整群等齊。
    ///
    /// merge-review R2 M4：迴圈開頭也檢查 `session.isCancelled`——這一群還沒讀完的其餘
    /// identifier 不再繼續讀取／入列（同 `enqueueGroups` 理由）；已經讀出的那幾筆維持不變，
    /// `markGroupResolved` 仍照跑一次，讓 `resolvedGroupCount` 的簿記保持一致。
    ///
    /// merge-review R3 m1：`await loadPendingUpload` 回來之後再檢查一次——取消當下最多
    /// `maxConcurrentGroupLoads` 筆已經在飛行中的讀取，若只在迴圈開頭檢查，這幾筆讀完後仍會
    /// 照樣 `registerPendingAlbum`／`session.append`／`store.enqueue`，使用者按了取消、畫面
    /// 已關，相簿之後仍會多出這幾張（見 handoff m1）。這幾筆算「取消時放棄」，不計入
    /// `droppedCount`（不是格式不支援／讀取失敗）。
    private func enqueue(group: ImportPlan.Group, into store: UploadQueueStore, session: ImportBatchSession) async {
        let anchorDate = min(group.anchorDate, Date())
        let albumID = group.albumID
        var droppedCount = 0
        for identifier in group.assetLocalIdentifiers {
            if session.isCancelled { break }
            let rawUploads = await loadPendingUpload(identifier)
            if session.isCancelled { break }
            guard !rawUploads.isEmpty else {
                droppedCount += 1
                continue
            }
            let uploads = rawUploads.map { upload in
                PendingUpload(
                    id: upload.id, kind: upload.kind, thumbnail: upload.thumbnail, pixelSize: upload.pixelSize,
                    takenAt: anchorDate
                )
            }
            for upload in uploads {
                if let albumID {
                    albumsStore.registerPendingAlbum(entryID: upload.id, albumID: albumID)
                }
                session.append(upload.id)
            }
            store.enqueue(uploads)
        }
        session.markGroupResolved(droppedCount: droppedCount)
    }

    // MARK: - PHAsset → PendingUpload（同 Legacy 既有理由：Photos 資料庫查詢離開 MainActor）

    /// 一個 identifier 讀不到對應的 `PHAsset`（例如使用者選取後、開始匯入前把這張刪了）或
    /// 讀出來的 asset 不支援／解不出來，一律回傳空陣列——呼叫端（`enqueue(group:...)`）把
    /// 空陣列算進 `droppedCount`（merge-review R1 M2），不是靜默消失。
    nonisolated static func loadPendingUpload(forIdentifier identifier: String) async -> [PendingUpload] {
        let asset = await Task.detached(priority: .userInitiated) { () -> PHAsset? in
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }.value
        guard let asset else { return [] }
        return await loadPendingUploads(for: asset)
    }

    /// 一個 `PHAsset` 可能展開成 0～2 筆：一般照片／影片各一筆；Live Photo 兩筆（照片＋配對
    /// 短片）。讀不到／不支援格式的整筆捨棄（回傳空陣列），同單張即傳既有的「讀不到就跳過，
    /// 不阻斷其餘項目」慣例。
    nonisolated private static func loadPendingUploads(for asset: PHAsset) async -> [PendingUpload] {
        switch asset.mediaType {
        case .video:
            return await loadVideoUpload(for: asset).map { [$0] } ?? []
        case .image:
            var results: [PendingUpload] = []
            if let photo = await loadPhotoUpload(for: asset) { results.append(photo) }
            // 票文範圍 2：Live Photo 保留照片＋短片——`mediaSubtypes` 判斷 Live Photo，
            // 配對短片走一般影片路徑（同樣受 `UploadQueueStore` 既有的 60 秒裁切規則）。
            if asset.mediaSubtypes.contains(.photoLive), let video = await loadLivePhotoPairedVideo(for: asset) {
                results.append(video)
            }
            return results
        default:
            return []
        }
    }

    nonisolated private static func loadPhotoUpload(for asset: PHAsset) async -> PendingUpload? {
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
        let rawExt = (result.dataUTI.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg").lowercased()
        guard PickedItemLoader.isSupportedExtension(rawExt, isVideo: false),
              let image = UIImage(data: result.data),
              let pixelSize = PickedItemLoader.orientedPixelSize(of: image)
        else { return nil }
        // 票文範圍 2（C2a）：HEIC／HEIF 轉成一般照片——轉檔失敗（來源解不出來，理論上走不到，
        // `UIImage(data:)` 已經先解過一次）就整筆捨棄，不上傳一張轉檔失敗的原始 HEIC。
        let (data, ext): (Data, String)
        if rawExt == "heic" || rawExt == "heif" {
            // merge-review R1 m4：`image` 上面幾行已經解過一次（算 `pixelSize` 用）——轉檔
            // 函式改收已解好的 `UIImage`，不用同一份 bytes 再讓 `UIImage(data:)` 解第二次。
            guard let jpegData = ImportMediaTranscoder.convertHEICToJPEG(image) else { return nil }
            (data, ext) = (jpegData, "jpg")
        } else {
            (data, ext) = (result.data, rawExt)
        }
        return PendingUpload(
            kind: .photo(data: data, fileExtension: ext),
            thumbnail: await PickedItemLoader.downsizedThumbnail(for: image), pixelSize: pixelSize
        )
    }

    nonisolated private static func loadVideoUpload(for asset: PHAsset) async -> PendingUpload? {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video || $0.type == .fullSizeVideo })
        else { return nil }
        return await writePendingVideoUpload(resource: resource)
    }

    /// Live Photo 的配對短片資源（`.pairedVideo`／`.fullSizePairedVideo`）——沒有配對短片
    /// （理論上不該發生，`mediaSubtypes.contains(.photoLive)` 已經先判斷過）就回傳 `nil`，
    /// 呼叫端只會少這一筆短片，靜態照片那一筆不受影響。
    nonisolated private static func loadLivePhotoPairedVideo(for asset: PHAsset) async -> PendingUpload? {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo })
        else { return nil }
        return await writePendingVideoUpload(resource: resource)
    }

    nonisolated private static func writePendingVideoUpload(resource: PHAssetResource) async -> PendingUpload? {
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
        return PendingUpload(
            kind: .video(fileURL: destination, fileExtension: ext),
            thumbnail: PickedItemLoader.firstFrame(of: avAsset), pixelSize: pixelSize
        )
    }
}
