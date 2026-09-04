import Foundation
import XCTest

/// LS-158：QA 端到端情境測試（`QASmokeTests`）的環境變數。`scripts/ops/qa-e2e.sh` 從 `supabase
/// status` 讀本機容器的 API URL／anon key／Mailpit URL，以 `TEST_RUNNER_<name>` 前綴交給 xcodebuild
/// （xcodebuild 會剝掉前綴塞進 test runner 行程），這裡讀到的就是 `LS_QA_*`。
///
/// 缺任何一個都 `XCTFail` 明說後丟錯——**不得靜默 skip**（票文範圍 1：紅就是紅，沒有「環境不齊
/// 所以跳過＝綠」這種事；CI 的 tap-target gate 用 `-skip-testing:LittleSproutUITests/QASmokeTests`
/// 明確不跑這支，不是靠這裡自己 skip）。
struct QAEnvironment {
    enum Scenario: String, CaseIterable {
        case login
        case publish
        case browse
    }

    static let scenarioKey = "LS_QA_SCENARIO"
    static let apiURLKey = "LS_QA_API_URL"
    static let anonKeyKey = "LS_QA_ANON_KEY"
    static let mailpitKey = "LS_QA_MAILPIT"
    static let emailKey = "LS_QA_EMAIL"
    /// 三個情境共用同一個帳號（`browse` 才看得到 `publish` 剛發的那篇），但**每個情境各自 OTP 登入**：
    /// `qa-e2e.sh` 跑前一律 `simctl keychain reset`——沿用上一情境的 session 在共用容器被他票 reset 後會
    /// 變成「使用者已不存在」的假缺陷（本票實測），重登只多 ~10 秒。
    static let defaultEmail = "qa-e2e@ls.test"

    let scenario: Scenario
    let apiURL: String
    let anonKey: String
    let mailpitURL: URL
    let email: String

    static func load(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> QAEnvironment {
        let required = [scenarioKey, apiURLKey, anonKeyKey, mailpitKey]
        let missing = required.filter { (env[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard missing.isEmpty else {
            XCTFail(
                "QA e2e 缺環境變數：\(missing.joined(separator: "、"))——請經 scripts/ops/qa-e2e.sh 執行"
                    + "（它從 supabase status 帶入本機容器的值），不要直接 xcodebuild test 這支測試"
            )
            throw QAFailure.environment
        }
        let rawScenario = env[scenarioKey] ?? ""
        guard let scenario = Scenario(rawValue: rawScenario) else {
            let allowed = Scenario.allCases.map(\.rawValue).joined(separator: "|")
            XCTFail("\(scenarioKey)=「\(rawScenario)」不是合法情境；只接受 \(allowed)")
            throw QAFailure.environment
        }
        let rawMailpit = env[mailpitKey] ?? ""
        guard let mailpitURL = URL(string: rawMailpit), mailpitURL.host != nil else {
            XCTFail("\(mailpitKey)=「\(rawMailpit)」不是合法 URL（預期像 http://127.0.0.1:54324）")
            throw QAFailure.environment
        }
        let email = env[emailKey].flatMap { $0.isEmpty ? nil : $0 } ?? defaultEmail
        return QAEnvironment(
            scenario: scenario, apiURL: env[apiURLKey] ?? "", anonKey: env[anonKeyKey] ?? "",
            mailpitURL: mailpitURL, email: email
        )
    }
}

/// 情境失敗的三種來源——丟出前一律先 `XCTFail` 說明（`QADriver.require`／`QAEnvironment.load`／
/// `QADriver.fetchOTP`），錯誤本身只負責讓 `testScenario` 提早結束，不重複報告。
enum QAFailure: Error {
    case environment
    case screen(String)
    case mailpit(String)
}

/// 從本機 Mailpit（`supabase start` 起的信件收件匣，port 沿用舊名 Inbucket）取 Email OTP。
/// GoTrue 本機用 `supabase/templates/otp.html`（LS-93）——新帳號的第一封與既有帳號都走同一份
/// 模板、內文明文 6 碼（2026-09-04 對本機 GoTrue 實測：新 email 打 `/auth/v1/otp` 收到的就是它）。
enum QAMailpit {
    struct Summary {
        let messageID: String
        let subject: String
    }

    /// 只認 `sentAfter` 之後（容 5 秒時鐘誤差）寄給 `email` 的信，舊信裡的舊碼不算——重跑情境
    /// 時 Mailpit 裡可能還留著上一輪的驗證碼，拿到舊碼會被 GoTrue 拒絕成「碼不對」、誤導成 app 缺陷。
    static func fetchOTP(
        mailpit: URL, email: String, sentAfter: Date, timeout: TimeInterval = 30
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let earliest = sentAfter.addingTimeInterval(-5)
        var lastSeen = "尚未看到任何寄給 \(email) 的新信"
        while Date() < deadline {
            if let summary = try await newestMessage(mailpit: mailpit, email: email, createdAfter: earliest) {
                let text = try await messageText(mailpit: mailpit, messageID: summary.messageID)
                if let code = sixDigitCode(in: text) { return code }
                lastSeen = "最新一封「\(summary.subject)」內文找不到 6 碼：\(text.prefix(160))"
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw QAFailure.mailpit("\(Int(timeout)) 秒內沒等到 OTP 信（\(lastSeen)）")
    }

    /// `(?<!\d)\d{6}(?!\d)`：整段剛好 6 碼的數字——排除時間戳之類更長的數字串。merge-review R1 I-4：先錨在
    /// 「驗證碼是」之後找（`otp.html` 的版型「你的驗證碼是：」緊接 `{{ .Token }}`），模板日後多了別的 6 碼數字
    /// （訂單號、日期串）也不會抓錯；找不到錨點（模板換了措辭）才退回整段第一個獨立 6 碼。
    static func sixDigitCode(in text: String) -> String? {
        let pattern = #"(?<!\d)\d{6}(?!\d)"#
        if let anchor = text.range(of: "驗證碼是"),
           let range = text[anchor.upperBound...].range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// `GET /api/v1/messages?limit=20`：清單新→舊，`To[].Address` 比對收件人、`Created` 比對時間。
    private static func newestMessage(mailpit: URL, email: String, createdAfter: Date) async throws -> Summary? {
        let list = try await getJSON(mailpit.appendingPathComponent("api/v1/messages"), query: "limit=20")
        let messages = list["messages"] as? [[String: Any]] ?? []
        for message in messages {
            let recipients = (message["To"] as? [[String: Any]] ?? []).compactMap { $0["Address"] as? String }
            guard recipients.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }),
                  let created = (message["Created"] as? String).flatMap(parseDate), created >= createdAfter,
                  let messageID = message["ID"] as? String else { continue }
            return Summary(messageID: messageID, subject: message["Subject"] as? String ?? "")
        }
        return nil
    }

    /// `GET /api/v1/message/<ID>`：`Text` 是純文字版內文（HTML 版另有 `HTML` 欄位，這裡不需要）。
    private static func messageText(mailpit: URL, messageID: String) async throws -> String {
        let message = try await getJSON(mailpit.appendingPathComponent("api/v1/message/\(messageID)"), query: nil)
        return message["Text"] as? String ?? ""
    }

    private static func getJSON(_ base: URL, query: String?) async throws -> [String: Any] {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.query = query
        guard let url = components?.url else { throw QAFailure.mailpit("組不出 URL：\(base)") }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw QAFailure.mailpit("\(url) 回 HTTP \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QAFailure.mailpit("\(url) 回的不是 JSON 物件")
        }
        return json
    }

    /// Mailpit 的 `Created` 形如 `2026-09-04T11:49:54.464Z`（有毫秒）；保險起見也接受無毫秒版本。
    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
