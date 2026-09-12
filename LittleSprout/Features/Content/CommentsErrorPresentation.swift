import Foundation

/// LS-218（依 LS-177 稿 `dHSyh` 網路錯誤態；LS026 換 icon／文案，稿面「同一版面」未獨立畫板，
/// 見 Handoff Notes `HMzhL`）——把 `list_comments`／`create_comment` 失敗時拿到的 `AppError`
/// 換算成留言 sheet 要顯示的 icon／標題／內文／要不要給重試鈕，抽成純函式方便單元測試，不依賴
/// View（同 `DiaryDeleteConfirmationCopy` 既有慣例）。
struct CommentsErrorPresentation: Equatable {
    let icon: String
    let title: String
    let message: String
    let showsRetry: Bool

    /// LS026（`LSErrorCode.targetFamilyMismatch`）——目標已被刪除或不屬於這個家庭：
    /// `list_comments`／`create_comment` 共用同一個碼，代表這則內容真的不在了，不是網路問題。
    /// 票文範圍 4 裁定「不提供重試，因為目標真的不在了」，同 Notes `HMzhL` 文案建議。
    static let targetGone = CommentsErrorPresentation(
        icon: "trash.slash", title: "找不到這則內容",
        message: "這則內容已經不存在了，無法查看或新增留言。", showsRetry: false
    )

    /// 網路錯誤（`AppError.network`）——`dHSyh` 稿面固定文案（`wifi-off` icon＋標題「連線中斷」
    /// ＋內文「請檢查網路連線後再試一次。」），不隨實際訊息變動。
    static let network = CommentsErrorPresentation(
        icon: "wifi.slash", title: "連線中斷", message: "請檢查網路連線後再試一次。", showsRetry: true
    )

    static func make(from error: AppError) -> CommentsErrorPresentation {
        if case .rejected(_, let code) = error, code == LSErrorCode.targetFamilyMismatch.rawValue {
            return .targetGone
        }
        if case .network = error {
            return .network
        }
        // 其餘錯誤（未預期的 42501／LS022／server…）：稿面沒有畫這些態，沿用網路錯誤態的
        // 版面骨架（icon＋標題＋內文＋重試），只是內文換成 `error.userFacingMessage`——同
        // `LikersListSheet` 對「查詢失敗」一律給可重試的既有裁量，不特別分流每一種碼。
        return CommentsErrorPresentation(
            icon: "exclamationmark.triangle", title: "無法載入留言", message: error.userFacingMessage, showsRetry: true
        )
    }

    var isTargetGone: Bool { self == .targetGone }
}
