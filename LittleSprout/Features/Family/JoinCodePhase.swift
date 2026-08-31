import Foundation

/// `JoinCodeView`（06／06b／06c）依 `FamilyStore.requestJoinState` 決定顯示哪一態——過期
/// （`LS011`）與次數用盡（`LS012`）各自有專屬文案與預寫訊息（票文 Scope 第 1 點「過期與次數
/// 用盡兩種文案分開」），其餘錯誤（碼不存在、已是成員、已有待審申請…）落回一般錯誤列，不需要
/// 專屬版面。抽成獨立、可測試的純值型別，理由同 `InvitePhase`（見該檔文件註解）。
enum JoinCodeFormPhase: Equatable {
    case idle
    case submitting
    /// 邀請碼已過期（06b）。
    case expired
    /// 邀請碼使用次數已用完（06c）。
    case exhausted
    /// 其餘錯誤（碼不存在、已是成員、已有待審申請、網路失敗…）——沿用一般 `errorRow` 顯示
    /// `error.userFacingMessage`，不需要專屬版面。
    case genericError(AppError)

    init(requestJoinState: FamilyOperationState) {
        if requestJoinState.isSubmitting {
            self = .submitting
            return
        }
        guard case .failure(let error) = requestJoinState else {
            self = .idle
            return
        }
        switch Self.code(of: error) {
        case LSErrorCode.inviteCodeExpired.rawValue:
            self = .expired
        case LSErrorCode.inviteCodeExhausted.rawValue:
            self = .exhausted
        default:
            self = .genericError(error)
        }
    }

    /// 六格邊框與判決句是否該切成「錯誤態」——過期／用盡／其他錯誤皆是，送出中／閒置不是。
    var isError: Bool {
        switch self {
        case .idle, .submitting: false
        case .expired, .exhausted, .genericError: true
        }
    }

    private static func code(of error: AppError) -> String? {
        switch error {
        case .validationRetryable(_, let code), .retryableSystem(_, let code),
             .rejected(_, let code), .server(_, let code):
            return code
        case .network:
            return nil
        }
    }
}
