import Foundation

/// 從「貼上邀請連結」（06／06b／06c 底部按鈕）、`sproutday://invite/<code>` deep link
/// （LS-39 已註冊 scheme）或 `https://sproutday.app/invite/<code>` 分享連結（LS-436）解析出邀請碼字串。兩個入口共用同一套規則：貼上的可能是完整連結、
/// 也可能是使用者直接複製的碼本身，這裡都嘗試解出來，交給 `InviteCodeField.normalize` 或
/// `request_join`（server 端已內建正規化，見 docs/API.md §7）做最終大寫／去空白。
enum InviteCodeParser {
    static let scheme = "sproutday"
    static let host = "invite"
    /// LS-436：分享連結（`InviteFamilyView.inviteURL`）的 https 網域；舊 `littlesprout.app` 不再認。
    static let universalLinkHost = "sproutday.app"

    /// `text` 可以是：
    /// 1. 完整 deep link，例如 `sproutday://invite/K7M2FD` 或 `https://sproutday.app/invite/K7M2FD`；
    /// 2. 使用者直接貼上的碼本身（含大小寫、空格、連字號皆可）。
    /// 解析不到任何英數字元時回傳 nil（例如剪貼簿是空的或貼了完全無關的文字）。
    static func extractCode(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 只有真的解析出一個「非本 app」的連結（例如使用者不小心貼了一段別的網頁連結）才視為
        // 「這不是邀請碼來源」直接回 nil；沒有 scheme（純文字／碼本身，含連字號、空格）落回
        // bare code 正規化。少了這個判斷，任何非 sproutday 連結會被整串當成文字硬過濾英數
        // 字元，湊出一串看起來像碼、其實完全是垃圾的字串（R1 實測：`https://invite/K7M2FD` 會被
        // 誤判成「HTTPSINVITEK7M2FD」）。
        if let url = URL(string: trimmed), url.scheme != nil {
            return code(fromDeepLink: url)
        }
        return normalize(trimmed)
    }

    /// 直接從 `onOpenURL` 拿到的 `URL` 解析（冷／熱啟動皆走這支）。
    static func code(fromDeepLink url: URL) -> String? {
        let path: String
        switch (url.scheme?.lowercased(), url.host?.lowercased()) {
        case (scheme, host):
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case ("https", universalLinkHost):
            // `https://sproutday.app/invite/<code>`：第一段必須是 `invite`，其後才是碼。
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 2, components[0].lowercased() == host else { return nil }
            path = components[1]
        default:
            return nil
        }
        guard !path.isEmpty else { return nil }
        return normalize(path)
    }

    private static func normalize(_ raw: String) -> String? {
        let filtered = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? nil : filtered
    }
}
