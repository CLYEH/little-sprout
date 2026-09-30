import Foundation

/// LS-410（`design/littlesprout.pen` Notes `k4oJhV`／`FBoLL`）：上傳佇列 sheet 的「態」與文案——純邏輯，不含 View。
///
/// **態只在打開 sheet 時判定一次**（brand 十條 #10：停留期間不搬版，把入口列 `bqnO1` 的情境邊界規則搬進 sheet）：
/// 開著期間只更新數字，不換態、不增減行。三態對應稿面 `rU2zY`／`KaONe`／`sq2SF`；②態下全部失敗都被標記
/// （M＝0）是 `x2it3Q` 的過渡文案，不是第四態（由 `failed == 0` 在文案層判斷）。
struct UploadQueueSheetSnapshot: Equatable {
    enum Mode: Equatable {
        /// ① inFlight>0：「正在新增照片」、「還有 N 張還沒完成」、footer「在背景繼續，關閉視窗」。
        case progress
        /// ② inFlight==0 且有失敗：「有 M 張照片沒有加進去」、footer「關閉」。
        case onlyFailed
        /// ③ inFlight==0、無失敗、K>0：「照片都加好了」＋3 欄縮圖格、footer「關閉」。
        case allDone
    }

    let mode: Mode
    /// 打開時失敗數 >1 才建立群標題列（右端「× 移除這 N 張」）；之後只換內容顯示與否，不增減這一列（`k4oJhV` R3）。
    let hasBatchRemoveRow: Bool
    /// 打開時失敗數 >1 且有可重試的，才有 Retry All Bar 的槽位；之後可重試數降到 0 只換槽內內容、保留槽高。
    let hasRetrySlot: Bool

    /// 純函式版本（單元測試直接餵數字）。`inFlight`＝等候＋上傳中；`completed`＝store 保留的已完成數。
    init(inFlight: Int, failed: Int, retryableFailed: Int, completed: Int) {
        if inFlight > 0 {
            mode = .progress
        } else if failed > 0 {
            mode = .onlyFailed
        } else {
            mode = completed > 0 ? .allDone : .progress
        }
        hasBatchRemoveRow = failed > 1
        hasRetrySlot = failed > 1 && retryableFailed > 0
    }

    @MainActor
    init(store: UploadQueueStore) {
        self.init(
            inFlight: store.waitingCount + store.uploadingCount, failed: store.failedCount,
            retryableFailed: store.retryableFailedCount, completed: store.completedCount
        )
    }

    /// footer 文案：進行中才是「在背景繼續，關閉視窗」（允許背景續傳），其餘態上傳已沒有東西在飛，只是「關閉」。
    var footerTitle: String {
        mode == .progress ? UploadQueueSheetCopy.footerContinue : UploadQueueSheetCopy.footerClose
    }
}

/// 稿面逐字文案。斷行一律靠 U+2060（WORD JOINER）＋U+00A0，稿面沒有任何手插換行（`fC2Rf`）：片語內字與字之間插
/// U+2060、標點黏在前一個字上，只留片語之間的斷點；同 `UploadQueueEntryCopy`。`phrases(_:)` 依此規則組字串：每個
/// 參數是一個片語（字字相連、不可斷），片語與片語之間留斷點。VoiceOver／UITest 用 `plain(_:)` 拿乾淨版（拿掉
/// U+2060、NBSP 換一般空白）。
enum UploadQueueSheetCopy {
    static let joiner = "\u{2060}"
    static let space = "\u{00A0}"

    private static func phrases(_ list: [String]) -> String {
        list.map { $0.map(String.init).joined(separator: joiner) }.joined()
    }

    private static func phrases(_ list: String...) -> String { phrases(list) }

    static let footerContinue = phrases("在背景繼續，", "關閉視窗")
    static let footerClose = "關閉"
    static let noRetry = phrases("沒有能重試的照片")
    static let allRemovedTitle = phrases("這幾張", "不加進相簿了")
    static let allRemovedMain = phrases("照片還在手機裡。", "關閉這個視窗前，", "都可以按「復原」", "放回來。")
    static let onlyFailedMain = phrases("看每張的原因，", "可以再試一次；", "不要的就移除，", "照片還在手機裡。")
    static let tombstoneText = phrases("已移除，", "不會加進", "相簿。")
    static let confirmMessage = "照片還在手機裡。關閉這個視窗前，都可以按「復原」放回來。"

    /// ② 態標題：M＝未標記的失敗數；全部標記（M＝0）換過渡句，不宣稱「都加好了」。
    static func onlyFailedTitle(failed: Int) -> String {
        guard failed > 0 else { return allRemovedTitle }
        return phrases("有\(space)\(failed)\(space)張照片", "沒有加進去")
    }

    static func onlyFailedMain(failed: Int) -> String { failed > 0 ? onlyFailedMain : allRemovedMain }

    static func allDoneMain(completed: Int) -> String { "\(completed)\(space)張都加進相簿了" }

    /// 「1 張等候上傳、1 張上傳中」——零的那半不出現。
    static func breakdown(waiting: Int, uploading: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting)\(space)張等候上傳" + (uploading > 0 ? "、" : "")) }
        if uploading > 0 { parts.append("\(uploading)\(space)張上傳中") }
        return phrases(parts)
    }

    static func batchRemoveTitle(count: Int) -> String { "移除這\(space)\(count)\(space)張" }
    static func confirmTitle(count: Int) -> String { "移除這 \(count) 張照片？" }
    static func confirmAction(count: Int) -> String { "移除這 \(count) 張" }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: joiner, with: "").replacingOccurrences(of: space, with: " ")
    }
}
