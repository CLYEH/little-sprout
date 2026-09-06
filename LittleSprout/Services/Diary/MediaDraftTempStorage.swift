import Foundation

/// 日記編輯器暫存媒體檔案的共用目錄與清理（LS-212，依 LS-96 `d8634a08` R1 m9／R2 n6 合併記：
/// 「草稿被 `removeSelected()` 移除、或使用者整個取消編輯器離開時，尚未上傳過的影片暫存檔
/// （`TransferableVideoFile` 複製檔／`VideoTrimmer` 裁切輸出）不會被清」）。
///
/// `TransferableVideoFile.importing`（`PickedItemLoader.swift`）與 `VideoTrimmer
/// .trimmedIfNeeded` 的暫存檔都寫進這個專屬子目錄，不是散落在 `.temporaryDirectory` 根目錄
/// 跟其他子系統（例如 `URLSession` 背景下載自己的暫存檔）混在一起——`purgeStaleFiles()` 才能
/// 安全地整批清空這個目錄，不會誤刪不相干的暫存檔。
///
/// **對帳依據**：`DiaryComposerStore` 不跨 App 重啟持久化——`DiaryEditorView.init()` 每次開
/// 編輯器都建立一份新的（見該檔文件註解），沒有任何本機資料庫／檔案記錄「上一個行程的佇列
/// 長怎樣」。因此下一次 App 啟動時，不可能有任何機制能認出這個目錄裡的某個檔案「還屬於一個
/// 現存的草稿」——每次啟動當下，這個目錄裡的任何殘留都必定是孤兒（例如 App 在編輯器開著、
/// 影片還沒上傳完成時被系統終止）。`LittleSproutApp.init()` 呼叫一次即可：呼叫時機早於任何
/// 畫面出現，不會跟同一個行程裡稍後才會發生的新草稿寫入互踩。
enum MediaDraftTempStorage {
    private static let directoryName = "ls-media-drafts"

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 呼叫端在寫入前確保目錄存在——`FileManager.copyItem`／`AVAssetExportSession.outputURL`
    /// 都要求目的目錄已存在，不會自己建立中繼目錄。
    @discardableResult
    static func makeDirectoryIfNeeded() throws -> URL {
        let url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 產生一個新的暫存檔路徑（呼叫端指定副檔名，不含點）——目錄不存在會先建立。
    static func newFileURL(extension fileExtension: String) throws -> URL {
        try makeDirectoryIfNeeded().appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    /// App 啟動時呼叫一次：整個目錄的內容都是上一個行程留下的孤兒（見上方文件註解），直接
    /// 移除目錄本身（而不是逐檔列舉刪除）最簡單；目錄不存在（全新安裝、或從未寫過任何草稿）
    /// 時安靜略過。best-effort：清不掉不影響任何功能，只是本機空間衛生（同
    /// `MediaUploadService.cleanupOrphans` 既有取捨）。
    static func purgeStaleFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}
