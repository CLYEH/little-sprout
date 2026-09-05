import Auth
import Foundation
import PostgREST

/// App 層統一錯誤分類，對應設計稿 k2Mw4 四層錯誤文法（LS-38 定案；四層敘述見 LS-49 ticket
/// scope 第 3 點／LS-38 comments）：
///
/// - `network`：連不上伺服器或逾時，使用者該做的事是檢查網路後重試。
/// - `validationRetryable`：這次操作本身有問題（輸入錯誤、碼過期、頻率限制…），
///   但修正輸入或稍後再試就可能成功。
/// - `retryableSystem`：跟 `validationRetryable` 一樣「重試同一個呼叫就可能成功」，但問題
///   出在系統本身的隨機性或暫時狀態（例如邀請碼產生時的亂數連續撞碼），不是使用者輸入
///   有誤——使用者沒有「可以修正的東西」，UI 不該引導使用者檢查輸入，只需要提示「請再試
///   一次」（見 `LSErrorCode.tier`；LS-55 N9）。
/// - `rejected`：沒有權限、帳號被拒絕，或流程層級的驗證失敗（例如 PKCE/JWT 驗證失敗）；
///   也包含「同一動作重試永遠不會成功、需要別的動作」的狀態衝突（見 `LSErrorCode.tier`）。
/// - `server`：後端本身出錯（5xx、格式看不懂的回應），不是使用者能修正的。
///
/// `message` 是後端／SDK 給的原始訊息，供 log／除錯用；`userFacingMessage` 才是可以直接
/// 顯示給使用者看的文案——後端訊息可能夾帶 HTML（例如 502 錯誤頁）或 SQL 錯字，不該直接上螢幕。
/// `code` 保留後端原始錯誤碼（Postgres SQLSTATE、本專案自訂 LS0xx、或 Auth 的 `ErrorCode`），
/// 供 UI 之後做更細的文案分流。
enum AppError: Error, Equatable {
    case network(message: String)
    case validationRetryable(message: String, code: String?)
    case retryableSystem(message: String, code: String?)
    case rejected(message: String, code: String?)
    case server(message: String, code: String?)

    /// 給使用者看的通用文案，不含任何後端細節。呼叫端要更精確的文案時可以另外依 `code` 分流，
    /// 這裡只保證「不會把後端的技術訊息洩漏到 UI」這個底線。
    var userFacingMessage: String {
        switch self {
        case .network:
            return "網路連線有問題，請檢查網路連線後再試一次。"
        case .validationRetryable:
            return "這個操作沒有成功，請確認內容後再試一次。"
        case .retryableSystem:
            return "請再試一次。"
        case .rejected:
            return "無法完成這個操作。"
        case .server:
            return "伺服器發生問題，請稍後再試一次。"
        }
    }
}

/// 本專案自訂 SQLSTATE 全碼（docs/API.md §5 錯誤碼全表；`LS1xx` 目前尚未使用，格式保留給未來）。
/// 與 §5 表的雙向集合一致由 `scripts/gates/error-codes-check.sh` 機械對帳（push-gate＋CI，LS-54）。
/// 逐碼列舉而不是字串前綴比對（LS-49 PR #63 review F4）：新碼若忘記歸類，在這裡會直接編不出來
/// 或被列舉測試抓到，不會被「開頭是 LS0」這種寬鬆比對悄悄吞進錯的分類。
enum LSErrorCode: String, CaseIterable, Sendable {
    case familyMustHaveOwner = "LS001"
    case storageQuotaExceeded = "LS002"
    case inviteCodeNotFound = "LS010"
    case inviteCodeExpired = "LS011"
    case inviteCodeExhausted = "LS012"
    case alreadyMember = "LS013"
    case alreadyHasPendingRequest = "LS014"
    case requestNotFoundOrProcessed = "LS015"
    case inviteCodeGenerationCollision = "LS016"
    case inviteParamsInvalid = "LS017"
    case diaryNotFoundOrDeleted = "LS020"
    case diaryNotEditableByCaller = "LS021"
    case timelineCursorIncomplete = "LS022"
    case albumNotFound = "LS023"
    case commentNotFound = "LS024"
    case commentNotEditableByCaller = "LS025"
    case targetFamilyMismatch = "LS026"
    case removedByOwnerNotRestorable = "LS027"
    // LS040（childFamilyImmutable）已於 LS-57 I1（orchestrator 裁決，2026-08-25）撤碼：
    // children 的 family_id 不可變 trigger 對齊 diaries／albums／comments，改用裸
    // 42501，不再有專屬碼，見下方 tier 與 §5 對應調整。
    case childNotFoundOrDeleted = "LS041"
    case childNotEditableByCaller = "LS042"
    case childRestoreWindowExpired = "LS043"
    case childDeletedCannotAttachContent = "LS044"
    // LS045（LS-121）：set_album_children 專用——不是相簿建立者本人，或雖是建立者
    // 但已不是該家庭 owner/member。同 diaryNotEditableByCaller／
    // commentNotEditableByCaller／childNotEditableByCaller 同一組理由，見下方 tier。
    case albumChildrenNotEditableByCaller = "LS045"
    // LS050（LS-143，delete_my_account）：呼叫者是家庭的唯一 owner、且家庭還有其他
    // 成員，須先轉移 owner 身份才能刪除帳號。同 familyMustHaveOwner（LS001）同一組
    // 不變量，只是觸發路徑不同，見下方 tier。
    case ownerMustTransferBeforeAccountDeletion = "LS050"
    // LS051（LS-151，過渡期擋寫）：deletion_requested_at 非 NULL 時，
    // families／family_members／media／diaries／albums／children／comments 七張表
    // 的 BEFORE INSERT trigger 一律拒絕——帳號已請求刪除，過渡期間不能再建立新資料。
    // 沒有輸入可換、也不是「先做別的事再重試」（跟 LS050 不同，這裡沒有任何後續動作
    // 能讓呼叫者自己解除這個狀態，只能等 Edge Function 完成刪除），純粹是狀態層級的
    // 拒絕，見下方 tier。本專案目前沒有任何 UI 會呼叫到會撞這個碼的路徑（LS-151 是
    // backend-only 票，帳號刪除的 UI 流程另票、需 Design gate）；三方對帳
    // （error-codes-check.sh）要求 API.md／migrations／LSErrorCode 三邊一致，這裡先
    // 補上列舉與分類，UI 落地時直接可用。
    case accountDeletionInProgress = "LS051"
    // LS052/LS053（LS-179，PLAN §10-B 停權旗標）：`profiles.suspended_at`／
    // `families.suspended_at` 非 NULL 時，RLS＋既有 RPC 入口一律拒絕。沒有輸入
    // 可換，只能等 Dashboard 解除，見下方 tier。
    case accountSuspended = "LS052"
    case familySuspended = "LS053"
    // LS054（LS-179，PLAN §10-A(3) 註冊開關）：`app_settings.registrations_open
    // = false` 時，自建新家庭一律拒絕（憑邀請碼加入既有家庭不受影響）。同
    // LS052/LS053 一樣是純狀態拒絕，見下方 tier。
    case registrationsClosed = "LS054"
    // LS055（LS-197，accept_eula）：p_version 與 app_settings.eula_version 目前
    // 值不相等——多半是呼叫端讀到的版本已經過期（條款版本已更新）。跟
    // LS052/LS053/LS054 同一組理由歸 rejected：呼叫端沒有「打錯字重打」這種
    // 輸入可換，需要先重新抓一次目前版本、重新顯示條款內容，才是正確的下一步
    // 動作，不是原地拿同一個 p_version 重試。
    case eulaVersionMismatch = "LS055"
    // LS056（LS-197 R2，accept_eula）：auth.uid() 沒有對應的 profiles 列——
    // 理論上不該發生（LS-110 保證每個帳號都有一列 profiles），出現代表資料
    // 不一致，不是使用者能自己解決的狀態，見下方 tier。
    case accountProfileMissing = "LS056"
    // LS057（LS-206，family_members 的 BEFORE DELETE trigger）：唯一 owner
    // 且家庭還有其他成員，退出或被移除前須先轉移 owner 身份。同
    // familyMustHaveOwner（LS001）／ownerMustTransferBeforeAccountDeletion
    // （LS050）同一組不變量，只是觸發路徑是直接對 family_members 的 DELETE。
    case ownerMustTransferBeforeLeaving = "LS057"
    // LS058/LS059/LS060（LS-206，transfer_ownership）：呼叫者不是該家庭目前
    // 的 owner／對方不是該家庭目前的成員／對方是呼叫者自己。三者皆是
    // transfer_ownership 的授權檢查，見下方 tier。
    case notFamilyOwner = "LS058"
    case transferTargetNotMember = "LS059"
    case cannotTransferToSelf = "LS060"

    enum Tier: Equatable {
        case validationRetryable
        case retryableSystem
        case rejected
    }

    /// 對應 k2Mw4 四層文法（＋LS-55 N9 補的 `retryableSystem` 層）的歸類準則：使用者換個
    /// 輸入、重試「同一個動作」是否可能成功——可能，而且是「使用者輸入」該換 →
    /// `validationRetryable`；可能，但不是使用者輸入的問題（純系統隨機性）→
    /// `retryableSystem`；即使換輸入也要先做別的事（先讓出一位 owner、等 owner 處理、拿
    /// 全新的邀請碼）→ `rejected`。
    var tier: Tier {
        switch self {
        case .familyMustHaveOwner, .storageQuotaExceeded,
             .alreadyMember, .alreadyHasPendingRequest, .requestNotFoundOrProcessed,
             .diaryNotFoundOrDeleted, .diaryNotEditableByCaller,
             .albumNotFound, .commentNotFound, .commentNotEditableByCaller,
             .targetFamilyMismatch, .timelineCursorIncomplete, .removedByOwnerNotRestorable,
             .childNotFoundOrDeleted, .childNotEditableByCaller, .childRestoreWindowExpired,
             .albumChildrenNotEditableByCaller, .ownerMustTransferBeforeAccountDeletion,
             .accountDeletionInProgress, .accountSuspended, .familySuspended,
             .registrationsClosed, .eulaVersionMismatch, .accountProfileMissing,
             .ownerMustTransferBeforeLeaving, .notFamilyOwner, .transferTargetNotMember,
             .cannotTransferToSelf:
            // 以下碼為 review 明確指定的案例：已是成員／已有待審／申請已處理，
            // 重試同一個 request_join／approve_join 呼叫永遠不會成功。
            // familyMustHaveOwner／storageQuotaExceeded 同理：都需要先做別的事
            // （指定新 owner、騰出空間或升級額度），不是「打錯字重打」能解的。
            // diaryNotFoundOrDeleted／diaryNotEditableByCaller（LS-54 補齊 LS020／LS021）同理：
            // 日記不存在或已軟刪要先還原、呼叫者已不是仍在家庭裡的作者——重送同一個
            // update_diary_entry／set_diary_deleted 不會變成功，要先做別的事。
            // albumNotFound／commentNotFound（LS-52，set_album_deleted／set_comment_deleted
            // 的 LS023／LS024；LS-58 起 commentNotFound 也用於 update_comment）同理：相簿或
            // 留言不存在，重送同一個 RPC 呼叫不會變成功，呼叫端該做的是回上一頁或重新整理
            // 清單，不是原地重試。commentNotEditableByCaller（LS-58 補齊 LS025，
            // update_comment）同理：不是作者本人、或雖是作者但已離開家庭，換輸入沒有用，
            // UI 該做的是隱藏編輯入口，不是讓使用者重試。targetFamilyMismatch（LS-58 R1
            // 補齊 LS026，create_comment／toggle_reaction）：target 存在但屬於別的家庭，
            // 是呼叫端組錯參數的訊號，不是「換個輸入再試」能解的，UI 該做的是回上一頁或
            // 重新整理，不是原地重試。
            // timelineCursorIncomplete（LS022）：游標參數（p_cursor_occurred_at／
            // p_cursor_ref_id，或 list_comments 的對應游標，LS-58）是 app 自己從上一頁回應
            // 組出來的，不是使用者手動輸入的東西——使用者沒有「換個輸入再送」這個動作可做，
            // 原地重試同一個呼叫不會變成功，該修的是呼叫端組游標的程式碼（或乾脆不帶游標
            // 重新查詢）。歸在這裡而不是 validationRetryable，才符合 N9 定的準則——
            // 「使用者能換輸入」才算 validationRetryable（PR #77 R1 B2(b)；orchestrator 裁決）。
            // removedByOwnerNotRestorable（LS-57 補齊 LS027，set_diary_deleted／
            // set_album_deleted／set_comment_deleted）：作者想還原一個 owner 已經移除的
            // 內容，換輸入沒有用（沒有輸入可換），只有請該家庭的 owner 出手還原這一條路，
            // UI 該做的是隱藏「還原」入口或提示「已被管理者移除」，不是讓使用者原地重試。
            // childNotFoundOrDeleted（LS041，LS-66）：孩子檔案不存在，或（update_child
            // 情境）已被軟刪除須先還原，同 diaryNotFoundOrDeleted 的理由。
            // childNotEditableByCaller（LS042，LS-66）：不是仍是該家庭 owner/member 的
            // 成員，同 diaryNotEditableByCaller 的理由——換輸入沒有用，UI 該隱藏編輯入口。
            // childRestoreWindowExpired（LS043，LS-66）：孩子檔案已被移除超過 30 天，
            // 無法還原——這是本票獨有的邊界，換輸入或重試同一個 set_child_deleted 呼叫
            // 都不會變成功，UI 該做的是不再顯示「還原」這個動作，不是引導使用者重試。
            // （childFamilyImmutable／LS040 已撤碼，見上方 case 列的說明——family_id
            // 不可變現在跟 diaries／albums／comments 一致，走下面 switch 的裸 "42501" 分支。）
            // albumChildrenNotEditableByCaller（LS045，LS-121）：不是相簿建立者本人、
            // 或雖是建立者但已不是該家庭 owner/member，同 diaryNotEditableByCaller 的
            // 理由——換輸入沒有用，UI 該做的是隱藏「編輯寶貝標記」入口。
            // ownerMustTransferBeforeAccountDeletion（LS050，LS-143）：呼叫者是家庭
            // 唯一 owner 且家庭還有其他成員，delete_my_account() 沒有輸入可換，必須
            // 先做別的事（把 owner 身份轉移給其他成員）才能重試，跟
            // familyMustHaveOwner 同一組理由。
            // accountDeletionInProgress（LS051，LS-151）：帳號已請求刪除，過渡期間
            // 的寫入一律拒絕。沒有輸入可換，也沒有使用者能自己做的「別的事」（跟
            // ownerMustTransferBeforeAccountDeletion 不同，這裡唯一的出路是等
            // Edge Function 完成刪除），純狀態拒絕，歸 rejected。
            // accountSuspended／familySuspended（LS052／LS053，LS-179，PLAN
            // §10-B）：帳號或家庭被 Dashboard 停權，沒有輸入可換，只能等
            // Dashboard 解除，同 accountDeletionInProgress 一樣是純狀態拒絕。
            // registrationsClosed（LS054，LS-179，PLAN §10-A(3)）：目前暫停開放
            // 新註冊，只擋自建新家庭這一步，沒有輸入可換，只能等旗標重新打開。
            // eulaVersionMismatch（LS055，LS-197）：呼叫端送的 p_version 已經
            // 過期，跟上面幾碼同一組「純狀態拒絕」——沒有「換個字重打」這種輸入
            // 可換，正確動作是重新抓目前版本、重新顯示條款，不是原地重試同一個
            // 呼叫。accountProfileMissing（LS056，LS-197 R2）：auth.uid() 沒有
            // 對應的 profiles 列，理論上不該發生，沒有輸入可換、也不是使用者
            // 能自己解決的狀態，只能聯絡支援排查。
            // ownerMustTransferBeforeLeaving（LS057，LS-206）：唯一 owner 且
            // 家庭還有其他成員，沒有輸入可換，必須先做別的事（轉移 owner 身份）
            // 才能退出或被移除，跟 familyMustHaveOwner／
            // ownerMustTransferBeforeAccountDeletion 同一組理由。
            // notFamilyOwner／transferTargetNotMember／cannotTransferToSelf
            // （LS058／LS059／LS060，LS-206，transfer_ownership）：三者都是
            // 授權／參數層級的拒絕，換個輸入重試同一組參數不會成功——呼叫端該做
            // 的是重新讀取自己的角色或該家庭的成員清單，不是原地重試。
            return .rejected
        case .inviteCodeNotFound, .inviteCodeExpired, .inviteCodeExhausted:
            // 碼本身是「輸入」——打錯字換一個、或請 owner 給一支新的碼，都是同一個 UI 動作
            // （輸入邀請碼）換個值再送出，跟 alreadyMember 那種「動作本身已經不適用」不同。
            return .validationRetryable
        case .inviteCodeGenerationCollision:
            // RPC 自己的訊息是「請重試」——單純的隨機碰撞，同樣的呼叫幾乎必然在下一次成功，
            // 但使用者沒有輸入任何東西可以「換掉」（他只是按了一次建立邀請碼），跟
            // inviteCodeNotFound 那種「使用者輸入有誤」的語意不同——歸 `retryableSystem`
            // 而不是 `validationRetryable`（LS-55 N9；PR #63 review R2）。
            return .retryableSystem
        case .inviteParamsInvalid:
            // 參數本身不合法（邀請設定超出範圍）：修正輸入之後同一個呼叫就會成功。
            return .validationRetryable
        case .childDeletedCannotAttachContent:
            // childDeletedCannotAttachContent（LS044，R1 補齊）：p_child_id 是使用者
            // 從孩子清單挑出來的「輸入」（同 inviteCodeNotFound 那組的理由，不是
            // childNotFoundOrDeleted 那種內部狀態檢查）——挑到的孩子剛好已被軟刪
            // （多半是清單快取過期），UI 該做的動作是重新整理孩子清單、讓使用者換一個
            // （或改成不指定），換輸入之後同一個 create_diary_entry／update_diary_entry
            // 呼叫就會成功，符合 N9「使用者能換輸入」的 validationRetryable 準則。
            return .validationRetryable
        }
    }
}

extension AppError {
    /// 把 Supabase SDK（Auth／PostgREST）或系統層的 `Error` 映射成上面幾類之一。
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
        if let httpError = error as? HTTPError {
            // 非 JSON 的錯誤回應（例如反向代理吐出的 502 HTML 頁）：PostgrestError 解不出來，
            // SDK 往外丟的是這個型別。仍然有狀態碼可以用，不必整包落 .server。
            return mapAPIStatus(
                httpError.response.statusCode,
                message: httpError.errorDescription ?? "HTTP \(httpError.response.statusCode)",
                code: nil
            )
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
        if let code, let lsCode = LSErrorCode(rawValue: code) {
            switch lsCode.tier {
            case .validationRetryable:
                return .validationRetryable(message: error.message, code: code)
            case .retryableSystem:
                return .retryableSystem(message: error.message, code: code)
            case .rejected:
                return .rejected(message: error.message, code: code)
            }
        }
        switch code {
        case "42501":
            // insufficient_privilege：未登入，或不是該操作要求的角色（例如非 owner）。
            return .rejected(message: error.message, code: code)
        case "PGRST301":
            // PostgREST 自己的碼：JWT 過期／驗證失敗。跟 42501 一樣是「需要重新登入」而非
            // 打錯輸入，歸 rejected。
            return .rejected(message: error.message, code: code)
        case "23505", "23514", "23503", "23502", "22P02", "22023":
            // unique/check/fk/not-null violation、輸入格式或參數不合法：使用者調整輸入可解。
            return .validationRetryable(message: error.message, code: code)
        default:
            return .server(message: error.message, code: code)
        }
    }

    private static func mapAPIStatus(_ statusCode: Int, message: String, code: String?) -> AppError {
        switch statusCode {
        case 401, 403:
            return .rejected(message: message, code: code)
        case 429:
            // 429（Too Many Requests）本身就是 HTTP 語意定義好的限流狀態碼；`code` 會是 nil
            // 的情況只發生在解不出結構化 error body 時（見 `map(_:)` 的 `HTTPError` 分支，
            // 例如反向代理直接吐出裸 429、沒有 GoTrue 的 JSON body）。呼叫端（例如
            // `OTPVerificationModel.nonAttemptConsumingCodes`）依 `code` 字串判斷是不是
            // 頻率限制，`code` 一旦是 nil 就會被誤判成一般驗證失敗而扣掉使用者的嘗試次數
            // ——這裡補一個可辨識的 sentinel，讓「裸 429」跟其他真的沒有 code 的
            // `.validationRetryable`（例如既有測試裡代表「純粹碼打錯」的
            // `code: nil`）區分開來（LS-92 R2 F4）。
            return .validationRetryable(message: message, code: code ?? "bare_http_429")
        case 400, 404, 422:
            return .validationRetryable(message: message, code: code)
        default:
            // 涵蓋 5xx 與任何其他未預期的狀態碼：後端沒有給出使用者能自行修正的訊號。
            return .server(message: message, code: code)
        }
    }
}
