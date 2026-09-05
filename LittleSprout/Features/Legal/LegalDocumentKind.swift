import Foundation

/// LS-191（依 LS-133 設計稿）：法務文件 in-app 檢視 sheet 可顯示的兩份文件。
///
/// `title` 是 Head 顯示的短標題，**不是**讀自 markdown 的 H1（H1 是完整名稱「萬芽日記
/// Little Sprout 使用條款／隱私權政策」，太長不適合當 Head 標題）——固定字串取自 LS-133
/// Notes `jaQmb` 的兩份文件字串對照表，兩份文件目前逐字相同，日後分岔也不影響這裡（這只是
/// 標題，不是版本／生效日期，那兩個欄位動態讀 markdown 檔頭，見 `LegalMarkdownDocument`）。
enum LegalDocumentKind: String, Identifiable, CaseIterable {
    case termsOfService
    case privacyPolicy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .termsOfService: "使用條款"
        case .privacyPolicy: "隱私權政策"
        }
    }

    /// bundle 內的檔名（不含副檔名），對應 `project.yml` 的 `resources:` 設定——兩份檔案
    /// 從 `docs/legal/*.md` 複製進 app bundle（build phase），路徑見該檔案。
    var bundleResourceName: String {
        switch self {
        case .termsOfService: "terms-of-service"
        case .privacyPolicy: "privacy-policy"
        }
    }

    /// `WelcomeView.legalAttributedString` 用的自訂 URL scheme——這兩個連結點擊後要開
    /// `LegalDocumentSheet`，不是真的要打開網址。`WelcomeView.body` 用
    /// `.environment(\.openURL, OpenURLAction { ... })` 攔截這個 scheme（見該檔文件註解，
    /// LS-133 Notes `GIe16`：原本開系統瀏覽器改為開 in-app sheet）。
    /// `rawValue` 是本檔固定的兩個 enum case 字面值，組出來的字串一定是合法 URL，這裡的
    /// 強制解包不會在執行期失敗。
    var linkURL: URL {
        URL(string: "legalsheet://\(rawValue)")!
    }

    init?(linkURL url: URL) {
        guard url.scheme == "legalsheet", let kind = LegalDocumentKind(rawValue: url.host ?? "") else {
            return nil
        }
        self = kind
    }
}
