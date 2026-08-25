import Foundation
import Observation

/// 03「輸入驗證碼」畫面的狀態機：驗證失敗計次、重寄冷卻倒數。
///
/// 輸錯行為（03b）維持既有設計：保留輸入內容＋顯示剩餘次數，不清空（Handoff Notes
/// 「OTP 輸錯行為維持既有」段）——`recordFailure()` 只遞減 `remainingAttempts`，不動 `code`。
/// 重寄才會清空並重置次數（新的一組碼理應重新給滿次數）。
///
/// R2（LS-92 PR #155 review R1，`comment 5412440073`）三個 major 同一根因：把伺服器端頻率
/// 限制用 app 自己的 60 秒重寄閘門（`resendCooldown`）來代表與呈現。這裡拆成三塊獨立、互不
/// 干擾的狀態：`lockMessage`（次數用盡，只有 resend 成功會清）、`verifyRateLimitSecondsRemaining`
/// （verify() 自己的 429，完全不碰 `resendCooldown`）、`isResendRateLimited`＋
/// `resendRateLimitSecondsAreReal`（resend() 自己的 429，沿用 `resendCooldown` 但秒數必須
/// 是從伺服器訊息解出來的真實值，解不出來就不承諾秒數）。
@MainActor
@Observable
final class OTPVerificationModel {
    let email: String
    let maxAttempts: Int
    let cooldownSeconds: Int

    private let authStore: AuthStore

    private(set) var code: String = ""
    private(set) var remainingAttempts: Int
    /// 一般碼錯／網路／伺服器錯誤（「還可以再試 N 次」那句、或 network／server 的
    /// `userFacingMessage`）。跟 `lockMessage` 分開存（R2 F1）：次數用盡後這個欄位不再更新，
    /// 畫面一律以 `lockMessage` 優先。
    private(set) var errorMessage: String?
    /// 次數用盡（R2 F1，取代原本共用 `errorMessage` 的做法）：只在 `recordFailure()` 把
    /// `remainingAttempts` 打到 0、或 `verify()` 發現已經是 0 時設定；**任何 rate-limit 分支
    /// 都不得寫這個欄位**——resend() 撞 `over_email_send_rate_limit` 時使用者仍應該看得到
    /// 「已達上限」這句話，不能被清掉（原 bug：`beginRateLimitCooldown()` 無條件
    /// `errorMessage = nil`，在共用欄位的舊設計下連鎖定理由一起清掉）。唯一會清掉它的地方
    /// 是 `resend()` 成功（次數重置，鎖定理由本來就不再成立）。
    private(set) var lockMessage: String?
    private(set) var isVerifying = false
    private(set) var isResending = false
    private(set) var resendCooldown: Int
    /// `resend()` 撞 `over_email_send_rate_limit`（或裸 429）時為真；只影響 `resendRow`
    /// 的文案選字，不影響 `errorMessage`／`lockMessage`（R2 F1／F2：resend 的頻率限制
    /// 是「resend 這個動作」的事，跟 OTP 欄位的錯誤／鎖定文法無關，也跟 verify() 自己的
    /// 頻率限制無關）。
    private(set) var isResendRateLimited = false
    /// 真——`resendCooldown` 目前顯示的秒數是從 GoTrue 錯誤訊息解析出來的真實剩餘秒數；
    /// 假——沒能解析出秒數，`resendCooldown` 只是內部節流用的備援值，**畫面不得顯示這個數字**
    /// （R2 F3：伺服器的頻率限制是小時級，app 自己的 60 秒常數在這種情境下是做不到的承諾）。
    private(set) var resendRateLimitSecondsAreReal = false
    /// `verify()` 撞 `over_request_rate_limit`（或裸 429）時的剩餘秒數；`nil`＝目前沒有 rate
    /// limit、`0`＝有 rate limit 但解不出真實秒數（只顯示靜態訊息、不倒數、也不擋下一次
    /// `verify()`）、`>0`＝有真實秒數在倒數（擋下一次 `verify()` 直到歸零）。刻意完全獨立於
    /// `resendCooldown`（R2 F2：原本 verify() 的 429 會呼叫 `beginRateLimitCooldown()` 把
    /// `resendCooldown` 重設回滿格，等於每按一次「確認登入」就把「重新寄一次」的冷卻往後
    /// 推——這裡兩條冷卻線徹底分開，互不觸碰）。
    private(set) var verifyRateLimitSecondsRemaining: Int?
    /// 次數用盡後使用者仍試著打新號碼的次數（R2 F5）：畫面觀察這個值的變化觸發按鍵回饋
    /// （震動／訊息輕微強調），不讓「打了沒反應」看起來像鍵盤壞掉。
    private(set) var lockedInputFeedbackTick = 0
    /// 沒有配 `deinit` 取消它：`@MainActor` class 的 `deinit` 不能同步存取 isolated 屬性，
    /// 這裡改用 `[weak self]`（見 `startCooldown()`）——model 被釋放後迴圈下一次
    /// `guard let self` 就會自然結束，不需要額外的取消路徑。
    private var cooldownTask: Task<Void, Never>?
    private var verifyRateLimitTask: Task<Void, Never>?
    /// 每次 `resend()` 成功遞增的世代計數。`verify()` 在 await 前記下當時的世代，await 回來後
    /// 若世代已變（代表使用者在等待期間重寄了新碼），整包結果（成功／失敗）都要丟棄，不能
    /// 用舊碼的驗證結果去污染新碼的 `remainingAttempts`／`errorMessage`（R2 review M2）。
    private var codeGeneration = 0

    init(email: String, authStore: AuthStore, maxAttempts: Int = 5, cooldownSeconds: Int = 60) {
        self.email = email
        self.authStore = authStore
        self.maxAttempts = maxAttempts
        self.cooldownSeconds = cooldownSeconds
        remainingAttempts = maxAttempts
        resendCooldown = cooldownSeconds
    }

    var canResend: Bool { resendCooldown <= 0 }
    var isCodeComplete: Bool { code.count == 6 }
    /// 次數用盡：這組碼已經不可能再驗證成功，只剩「重新寄一組」這條路（I-2，LS-92）。
    /// 用來擋掉 `updateCode` 的無意義輸入（新增數字那半——退格仍然放行，見 R2 F5）；刻意
    /// 不用來把 `PrimaryButton`／`OTPCodeField` 畫成灰階或按不下去的樣子——elder-constraints
    /// 「驗證型 disable＝0，只在 in-flight 才 disable」是 gate 級硬約束。輸入與按鈕看起來仍可
    /// 操作，動作被 `verify()` 的 guard 與這裡溫和擋下，用文字（`lockMessage`）說明原因，
    /// 不靠視覺停用。
    var isLocked: Bool { remainingAttempts <= 0 }
    /// `verify()` 自己的頻率限制目前是否有「真實秒數」在倒數擋著下一次呼叫（R2 F2）。
    /// `verifyRateLimitSecondsRemaining == 0`（有訊息、沒有可信秒數）刻意不算在內：沒有真實
    /// 依據就不擋，讓使用者可以馬上再試一次，而不是被一個編出來的等待時間卡住。
    private var isVerifyRateLimitGuardActive: Bool { (verifyRateLimitSecondsRemaining ?? 0) > 0 }

    func updateCode(_ newValue: String) {
        let filtered = String(newValue.filter(\.isNumber).prefix(6))
        // 鎖定時只放行「從目前碼尾端刪除」得到的結果（含清空）——`code.hasPrefix(filtered)`
        // 同時涵蓋退格與清空，擋掉新增或置換數字（R2 F5）。完全靜默吞鍵會讓長輩以為鍵盤
        // 壞了；擋下時 tick 遞增，讓 View 能觸發按鍵回饋（震動／訊息輕微強調）。
        if isLocked, !code.hasPrefix(filtered) {
            lockedInputFeedbackTick += 1
            return
        }
        code = filtered
    }

    /// 錯誤先依 `AppError` 四層文法分流才決定要不要扣次數：只有真的是「這組碼不對」
    /// （`.validationRetryable`／`.rejected`）才算使用者用掉一次機會；`.network`／
    /// `.retryableSystem`／`.server` 是環境或系統的問題，不是碼錯，不該扣長輩的嘗試次數
    /// （R2 review M1——電梯／收訊死角按下確認登入時，網路錯誤原本會被誤判成碼錯）。
    @discardableResult
    func verify() async -> Bool {
        guard !isVerifying, isCodeComplete else { return false }
        guard remainingAttempts > 0 else {
            errorMessage = nil
            lockMessage = attemptsExhaustedMessage
            return false
        }
        // R2 F2：verify() 自己的頻率限制有真實倒數在擋，就不再重打伺服器——每按一次都重打
        // 原本是問題根因之一（連帶把 resendCooldown 重設回滿格，見 beginResendRateLimit）。
        guard !isVerifyRateLimitGuardActive else { return false }
        verifyRateLimitTask?.cancel()
        verifyRateLimitSecondsRemaining = nil
        isVerifying = true
        defer { isVerifying = false }
        let generationAtStart = codeGeneration
        do {
            try await authStore.verifyEmailOTP(email: email, token: code)
            // 驗證中若使用者已重寄新碼，這個成功結果對應的是舊碼，不該用來放行（見 resend()）。
            guard generationAtStart == codeGeneration else { return false }
            errorMessage = nil
            lockMessage = nil
            return true
        } catch {
            // 同上：世代已變就整包丟棄，不動 remainingAttempts／errorMessage（R2 review M2）。
            guard generationAtStart == codeGeneration else { return false }
            applyVerificationFailure(error)
            return false
        }
    }

    /// 只有 rate-limit 碼不該算使用者用掉一次嘗試（R4 review A1，修正 R3 引入的回歸）：
    /// 打太快跟這組碼本身無關，該提示使用者等一下，不是暗示「碼打錯了」。
    ///
    /// `otp_expired` **刻意不在這個集合裡**：本機 GoTrue v2.195.0 實測（`scripts/ops/
    /// supabase-lock.sh` 序列化跑的三段 curl）——剛寄出、仍在有效期內的碼被打錯（例如
    /// 全填 000000）也回 403 `otp_expired`／`"Token has expired or is invalid"`。GoTrue
    /// 刻意把「碼不對」與「碼過期」壓成同一個碼與同一句訊息（防帳號／碼列舉），訊息裡的
    /// "or is invalid" 就是證據。R3 把 `otp_expired` 當成「一定是過期」而跳過計次，
    /// 長輩打錯碼時反而看到「已經過期」、次數不扣、又撞上重寄冷卻——唯一有用的提示
    /// 「還可以再試」永遠出不來。所以 `otp_expired` 照一般打錯碼處理：計次＋誠實文案
    /// （見 `recordFailure()`），不能二選一斷言成「一定是過期」。
    ///
    /// `bare_http_429`（R2 F4）：反向代理／SDK 解不出結構化 error body 時的裸 429
    /// （見 `AppError.mapAPIStatus`）。429 這個 HTTP 狀態碼本身就是限流語意，不該因為
    /// 「剛好沒有 JSON body」就被誤判成一般碼錯而扣次數。
    private static let nonAttemptConsumingCodes: Set<String> = [
        "over_request_rate_limit",
        "over_email_send_rate_limit",
        "bare_http_429"
    ]

    /// 從 GoTrue 的限流錯誤訊息（實測本機 GoTrue v2.195.0：`"For security purposes, you can
    /// only request this after 58 seconds."`）解析出真實剩餘秒數。解不出來（例如以請求次數
    /// 計的限流，訊息裡本來就沒有秒數）回傳 `nil`——呼叫端必須把「沒有可信秒數」當成一等
    /// 狀態處理，不能用 app 自己的常數頂替（R2 F3）。
    private static func parseRealRetryAfterSeconds(from message: String) -> Int? {
        guard let range = message.range(of: #"after (\d+) second"#, options: .regularExpression) else {
            return nil
        }
        let digits = message[range].filter(\.isNumber)
        guard let seconds = Int(digits), seconds > 0 else { return nil }
        return seconds
    }

    private func applyVerificationFailure(_ error: Error) {
        let appError = AppError.map(error)
        switch appError {
        case .validationRetryable(let message, let code), .rejected(let message, let code):
            if let code, Self.nonAttemptConsumingCodes.contains(code) {
                // R2 F2：文案歸屬對到 verify() 這個 call site（「太多次嘗試了」），不是
                // resend() 的「寄太頻繁了」——兩者是不同的動作，訊息不能互相冒充。
                beginVerifyRateLimit(rawMessage: message)
            } else {
                recordFailure()
            }
        case .network, .retryableSystem, .server:
            errorMessage = appError.userFacingMessage
        }
    }

    /// I-2（LS-92，review comment `78b4455c` informational）：歸零那一次不能再顯示
    /// 「還可以再試 0 次」——長輩看得到「0」還說「可以再試」，是矛盾句。改用跟 `verify()`
    /// guard 分支共用的同一份「已達上限」文案（`attemptsExhaustedMessage`），寫進獨立的
    /// `lockMessage`（R2 F1），不是 `errorMessage`。
    private func recordFailure() {
        remainingAttempts = max(0, remainingAttempts - 1)
        if remainingAttempts == 0 {
            errorMessage = nil
            lockMessage = attemptsExhaustedMessage
        } else {
            errorMessage = "驗證碼不對或已經過期，還可以再試 \(remainingAttempts) 次；沒收到的話請重新寄一組。"
        }
    }

    private var attemptsExhaustedMessage: String {
        "已經試了 \(maxAttempts) 次，已達上限，請重新寄一組驗證碼再試。"
    }

    /// R2 F2：verify() 自己的 429，完全獨立於 `resendCooldown`——不呼叫 `startCooldown()`，
    /// 不動 `resendRow` 顯示的任何東西。有真實秒數才倒數並擋下一次 `verify()`
    /// （`isVerifyRateLimitGuardActive`）；沒有就只留一句靜態訊息，讓使用者可以馬上再試
    /// （R2 F3：不編一個假的等待時間出來擋人）。
    private func beginVerifyRateLimit(rawMessage: String) {
        verifyRateLimitTask?.cancel()
        guard let seconds = Self.parseRealRetryAfterSeconds(from: rawMessage) else {
            verifyRateLimitSecondsRemaining = 0
            return
        }
        verifyRateLimitSecondsRemaining = seconds
        verifyRateLimitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tickVerifyRateLimit()
            }
        }
    }

    /// 跟 `tickCooldown()` 同樣的理由拆成獨立、可被測試直接呼叫的一次遞減（Rule 5）。
    /// 真實倒數走完（`next == 0`）要整個回到 `nil`（沒有 rate limit），不是停在 `0`——
    /// `0` 專門代表「有訊息、解不出真實秒數」那個獨立狀態，倒數完全結束不該落回那裡。
    func tickVerifyRateLimit() {
        guard let remaining = verifyRateLimitSecondsRemaining, remaining > 0 else { return }
        let next = remaining - 1
        if next == 0 {
            verifyRateLimitSecondsRemaining = nil
            verifyRateLimitTask?.cancel()
        } else {
            verifyRateLimitSecondsRemaining = next
        }
    }

    /// R2 F2：resend() 自己的 429（`over_email_send_rate_limit`／裸 429）沿用 `resendCooldown`
    /// 這條既有的冷卻機制（`resendRow` 本來就是「顯示還要等多久才能重寄」的位置，語意上
    /// 合適），但秒數必須是從伺服器訊息解出來的真實值才能顯示（`resendRateLimitSecondsAreReal`）
    /// ——解不出來就退回 app 自己的 `cooldownSeconds` 當內部節流的備援值，這個數字本身
    /// **不會被顯示**，畫面只給一句不承諾秒數的訊息（R2 F3）。
    private func beginResendRateLimit(rawMessage: String) {
        isResendRateLimited = true
        if let seconds = Self.parseRealRetryAfterSeconds(from: rawMessage) {
            resendRateLimitSecondsAreReal = true
            startCooldown(seconds: seconds)
        } else {
            resendRateLimitSecondsAreReal = false
            startCooldown(seconds: cooldownSeconds)
        }
    }

    @discardableResult
    func resend() async -> Bool {
        guard canResend, !isResending else { return false }
        isResending = true
        defer { isResending = false }
        do {
            try await authStore.sendEmailOTP(email: email)
            codeGeneration += 1
            code = ""
            remainingAttempts = maxAttempts
            errorMessage = nil
            lockMessage = nil
            isResendRateLimited = false
            resendRateLimitSecondsAreReal = false
            verifyRateLimitTask?.cancel()
            verifyRateLimitSecondsRemaining = nil
            startCooldown()
            return true
        } catch {
            let appError = AppError.map(error)
            switch appError {
            case .validationRetryable(let message, let code), .rejected(let message, let code):
                if let code, Self.nonAttemptConsumingCodes.contains(code) {
                    beginResendRateLimit(rawMessage: message)
                } else {
                    errorMessage = appError.userFacingMessage
                }
            case .network, .retryableSystem, .server:
                errorMessage = appError.userFacingMessage
            }
            return false
        }
    }

    func startCooldown() {
        startCooldown(seconds: cooldownSeconds)
    }

    private func startCooldown(seconds: Int) {
        resendCooldown = seconds
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.resendCooldown > 0 else { return }
                self.tickCooldown()
            }
        }
    }

    /// 冷卻倒數的一次遞減，跟驅動它的計時器（`startCooldown()`）分開，測試才能不靠真的
    /// `Task.sleep` 就驗證倒數邏輯（Rule 5：不用模型跑計時器測試，用確定性的呼叫）。
    func tickCooldown() {
        resendCooldown = max(0, resendCooldown - 1)
        if resendCooldown == 0 {
            isResendRateLimited = false
            resendRateLimitSecondsAreReal = false
        }
    }
}
