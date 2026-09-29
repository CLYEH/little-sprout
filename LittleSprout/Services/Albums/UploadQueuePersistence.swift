import Foundation
import os

/// LS-397（LS-20 背景續傳路線 (b)）：`UploadQueueStore` 未完成項的落盤紀錄——app 被系統回收、
/// 重新啟動後至少能把「還沒傳完」的項目列回佇列並重試（不要求接回原本的 `URLSession`，那是
/// 路線 (a) 的後續票）。
///
/// **只落盤重啟後還需要的東西**：等候／上傳中／可重試失敗這三種尚未終局的項目；完成與不可重試
/// 失敗（`UploadQueueStore.releasesPayload`）的項目 payload 本來就已釋放，不落盤。狀態本身不
/// 存——重啟後一律當 `.waiting` 重來（飛行中的位元組不可能還在，見 `restorePersistedEntries`）。
/// 縮圖不存（重啟後列用系統色塊佔位，同 `UploadQueueRowView` 既有的 nil-thumbnail 退回）。
///
/// **payload 檔案放 Application Support 而不是 tmp**：`MediaDraftTempStorage.purgeStaleFiles()`
/// 每次啟動都會清掉整個 tmp 草稿目錄，`PickedItemLoader`／`AlbumImportUploadCoordinator` 產生
/// 的影片暫存檔重啟後必定不見，所以影片要在入列時用硬連結（同一個 APFS volume，不佔第二份
/// 空間；連結失敗才退回複製）另存一份路徑，原暫存檔照舊由上傳成功後的清理刪掉。
struct PersistedUploadRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case photo
        case video
    }

    let id: UUID
    let kind: Kind
    let fileExtension: String
    /// 相對 `UploadQueuePersistence.directory` 的檔名——不存絕對路徑：app 更新後容器路徑會變。
    let payloadFileName: String
    let pixelWidth: Int
    let pixelHeight: Int
    let takenAt: Date?
    let enqueuedAt: Date
    /// 這筆完成後要掛進哪本相簿（`AlbumsStore.pendingUploadAlbumIDs` 的落盤副本）——重啟後由
    /// `AlbumsStore` 重新登記，否則續傳成功的照片會進 `media` 卻不會掛進相簿。
    let albumID: UUID?
    /// LS-397 R1 M2：批次匯入「指定寶貝」的寶貝 id（標記追蹤器對這筆的落盤副本）——重啟後重新登記進
    /// 追蹤器，續傳成功才補得上標記；舊版 manifest 沒有這個 key，解碼為 `nil`。
    var babyIDs: [UUID]?

    /// 入列當下向外部（`AlbumsStore`）查到的「這筆的連結」，落進 record。
    struct Links {
        var albumID: UUID?
        var babyIDs: [UUID]?
        static let none = Links(albumID: nil, babyIDs: nil)
    }
}

struct UploadQueuePersistence: Sendable {
    let directory: URL

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.leoyeh.littlesprout", category: "upload-queue"
    )

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// 正式路徑：`Application Support/UploadQueue/<familyID>/`——依家庭分開，同一台裝置換帳號
    /// 登入時不會撿到上一個家庭的未完成項（登出另外會整個清掉，見 `AlbumsStore.reset()`）。
    static func standard(familyID: UUID) -> UploadQueuePersistence? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return UploadQueuePersistence(
            directory: base.appendingPathComponent("UploadQueue", isDirectory: true)
                .appendingPathComponent(familyID.uuidString, isDirectory: true)
        )
    }

    // MARK: - manifest

    func loadRecords() -> [PersistedUploadRecord] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        do {
            return try JSONDecoder().decode([PersistedUploadRecord].self, from: data)
        } catch {
            Self.logger.error("manifest 解碼失敗，視為空佇列：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ records: [PersistedUploadRecord]) {
        do {
            try makeDirectoryIfNeeded()
            try JSONEncoder().encode(records).write(to: manifestURL, options: .atomic)
        } catch {
            Self.logger.error("manifest 寫入失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - payload

    /// 把入列項目的 payload 存成 `<id>.<ext>`，回傳相對檔名；失敗回 `nil`——這筆照常上傳，只是
    /// 不會出現在重啟後的佇列（fail loud：寫 log，不靜默）。
    func storePayload(id: UUID, kind: PendingUpload.Kind) -> String? {
        let ext: String
        switch kind {
        case .photo(_, let fileExtension), .video(_, let fileExtension): ext = fileExtension
        }
        let fileName = "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try makeDirectoryIfNeeded()
            try? FileManager.default.removeItem(at: destination)
            switch kind {
            case .photo(let data, _):
                try data.write(to: destination, options: .atomic)
            case .video(let fileURL, _):
                do {
                    try FileManager.default.linkItem(at: fileURL, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: fileURL, to: destination)
                }
            }
            return fileName
        } catch {
            Self.logger.error("payload 落盤失敗（這筆重啟後不會續傳）：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 重啟後把 payload 讀回 `PendingUpload.Kind`；檔案不見（被使用者／系統清掉）回 `nil`。
    func payload(for record: PersistedUploadRecord) -> PendingUpload.Kind? {
        let url = directory.appendingPathComponent(record.payloadFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        switch record.kind {
        case .photo:
            guard let data = try? Data(contentsOf: url) else { return nil }
            return .photo(data: data, fileExtension: record.fileExtension)
        case .video:
            return .video(fileURL: url, fileExtension: record.fileExtension)
        }
    }

    func removePayload(named fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// 刪掉不在 `keeping` 裡的 payload 檔（入列寫了 payload、還沒來得及存 manifest 就被回收的
    /// 孤兒）；manifest 本身不動。
    func pruneOrphans(keeping fileNames: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name != "manifest.json" && !fileNames.contains(name) {
            removePayload(named: name)
        }
    }

    /// 整個目錄移除——登出時呼叫（未完成的家庭照片不該在登出後還留在裝置上）。
    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDirectoryIfNeeded() throws {
        var url = directory
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 佇列裡的原圖／影片不進 iCloud 備份（可重新選取，也是家庭私密內容）。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
