import Foundation

// LS-427（來源 LS-417 QA R1 BLOCKED、LS-410 QA R1 同型）：QA 要驗「上傳到一半切出 app 回來續傳」「失敗項走查」，
// 但本機 30 張約 700KB 幾秒就傳完、沒有停滯點；QA 曾用 `docker pause supabase_storage_*` 製造停滯，被 Claude Code
// 分類器拒（且 pause 共用容器會影響同機其他 QA）。改成 app 端的 DEBUG-only 啟動開關：
//   LS_QA_UPLOAD_STALL_MS=<n>      每筆 `UploadQueueStore.performUpload` 開頭先 sleep n 毫秒
//   LS_QA_UPLOAD_FAIL_EVERY_N=<k>  該 store 生命週期內第 k、2k… 次 `performUpload` 呼叫丟可重試錯誤（`AppError.network`
//                                  → `UploadFailureReason.network`，`isRetryable == true`）；重試也算一次呼叫
// 兩者只在 `LS_QA_API_URL` 存在（＝QA 環境，同 `SupabaseClientFactory.qaOverride`）時讀；值必須是正整數，否則視為未設。
// 經 `xcrun simctl launch` 用 `SIMCTL_CHILD_` 前綴帶入，或 `qa-e2e.sh upload-stall` 經 XCUITest launchEnvironment。
// Release build：只留一個什麼都不做的 `QAUploadGate` 佔位型別（讓 store 的呼叫點不必條件編譯），讀環境變數
// 與計數／延遲／失敗邏輯全在 `#if DEBUG` 內。

#if DEBUG
struct QAUploadSwitches: Equatable {
    static let apiURLKey = "LS_QA_API_URL"
    static let stallKey = "LS_QA_UPLOAD_STALL_MS"
    static let failEveryNKey = "LS_QA_UPLOAD_FAIL_EVERY_N"

    var stallMilliseconds: Int?
    var failEveryN: Int?

    static let none = QAUploadSwitches(stallMilliseconds: nil, failEveryN: nil)

    static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> QAUploadSwitches {
        guard let apiURL = environment[apiURLKey], !apiURL.isEmpty else { return .none }
        return QAUploadSwitches(
            stallMilliseconds: positiveInt(environment[stallKey]), failEveryN: positiveInt(environment[failEveryNKey])
        )
    }

    private static func positiveInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value > 0 else { return nil }
        return value
    }
}

/// `UploadQueueStore.performUpload` 開頭呼叫一次：先依 STALL 延遲，再依 FAIL_EVERY_N 判斷這次是否要丟錯。
@MainActor
final class QAUploadGate {
    var switches: QAUploadSwitches
    private let sleep: (Duration) async throws -> Void
    private var calls = 0

    init(
        switches: QAUploadSwitches = .from(),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.switches = switches
        self.sleep = sleep
    }

    func beforeUpload() async throws {
        calls += 1
        if let stall = switches.stallMilliseconds {
            try await sleep(.milliseconds(stall))
        }
        if let every = switches.failEveryN, calls % every == 0 {
            throw AppError.network(message: "\(QAUploadSwitches.failEveryNKey)=\(every)：第 \(calls) 次呼叫")
        }
    }
}
#else
struct QAUploadGate {
    func beforeUpload() async throws {}
}
#endif
