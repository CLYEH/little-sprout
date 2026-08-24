import Auth
import Foundation
import PostgREST

/// App 層統一錯誤分類，對應設計稿 k2Mw4 四層錯誤文法（LS-38 定案；四層敘述見 LS-49 ticket
/// scope 第 3 點／LS-38 comments）：
///
/// - `network`：連不上伺服器或逾時，使用者該做的事是檢查網路後重試。
/// - `validationRetryable`：這次操作本身有問題（輸入錯誤、碼過期、頻率限制…），
///   但修正輸入或稍後再試就可能成功。
/// - `rejected`：沒有權限、帳號被拒絕，或流程層級的驗證失敗（例如 PKCE/JWT 驗證失敗）。
///   單純重試沒有意義，需要不同的動作（重新登入、聯絡 owner…）。
/// - `server`：後端本身出錯（5xx、格式看不懂的回應），不是使用者能修正的。
///
/// `code` 保留後端原始錯誤碼（Postgres SQLSTATE、本專案自訂 LS0xx、或 Auth 的 `ErrorCode`），
/// 供 UI 之後做更細的文案分流，不在這裡預先決定文字內容。
enum AppError: Error, Equatable {
    case network(message: String)
    case validationRetryable(message: String, code: String?)
    case rejected(message: String, code: String?)
    case server(message: String, code: String?)
}

extension AppError {
    /// 把 Supabase SDK（Auth／PostgREST）或系統層的 `Error` 映射成上面四類之一。
    ///
    /// Fail loud 的取捨：任何辨認不出來的錯誤一律落在 `.server`，不會有第五種「未知」分類
    /// 讓呼叫端誤以為可以安全忽略——`.server` 逼呼叫端至少顯示「發生錯誤」而不是靜默吞掉。
    static func map(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        if let urlError = error as? URLError {
            return .network(message: urlError.localizedDescription)
        }
        if let authError = error as? AuthError {
            return map(authError)
        }
        if let postgrestError = error as? PostgrestError {
            return map(postgrestError)
        }
        return .server(message: (error as? LocalizedError)?.errorDescription ?? "\(error)", code: nil)
    }

    private static func map(_ error: AuthError) -> AppError {
        switch error {
        case .sessionMissing:
            return .rejected(message: error.message, code: error.errorCode.rawValue)
        case .weakPassword:
            return .validationRetryable(message: error.message, code: error.errorCode.rawValue)
        case .pkceGrantCodeExchange, .implicitGrantRedirect, .jwtVerificationFailed:
            // 流程／簽章層失敗：不是「打錯字重來就好」，需要重新走一次完整登入流程。
            return .rejected(message: error.message, code: error.errorCode.rawValue)
        case .api(let message, let errorCode, _, let response):
            return mapAPIStatus(response.statusCode, message: message, code: errorCode.rawValue)
        default:
            // 涵蓋已 deprecated 但仍可能出現的舊 case；不是這個分類函式該負責的錯誤語意，
            // 保守落 server 而不是猜。
            return .server(message: error.message, code: error.errorCode.rawValue)
        }
    }

    private static func map(_ error: PostgrestError) -> AppError {
        let code = error.code
        switch code {
        case let lsCode? where lsCode.hasPrefix("LS0"):
            // 本專案自訂錯誤碼（LS010~LS017，見
            // supabase/migrations/20260823010000_join_approval.sql 檔頭清單）：
            // 邀請碼打錯／過期／用完／已是成員／已有待審／參數不合法──全部是「調整輸入或
            // 換個時機再試」就可能成功的失敗。
            return .validationRetryable(message: error.message, code: lsCode)
        case "42501":
            // insufficient_privilege：未登入，或不是該操作要求的角色（例如非 owner）。
            return .rejected(message: error.message, code: code)
        case "23505", "23514", "23503", "23502", "22P02", "22023":
            // unique/check/fk/not-null violation、輸入格式或參數不合法：使用者調整輸入可解。
            return .validationRetryable(message: error.message, code: code)
        default:
            return .server(message: error.message, code: code)
        }
    }

    private static func mapAPIStatus(_ statusCode: Int, message: String, code: String) -> AppError {
        switch statusCode {
        case 401, 403:
            return .rejected(message: message, code: code)
        case 400, 404, 422, 429:
            return .validationRetryable(message: message, code: code)
        default:
            // 涵蓋 5xx 與任何其他未預期的狀態碼：後端沒有給出使用者能自行修正的訊號。
            return .server(message: message, code: code)
        }
    }
}
