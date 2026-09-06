import SwiftUI

/// LS-190（依 LS-152 稿 `oFRMc`／`Qs7iE`）：刪除單筆內容（日記／留言）的確認 sheet——通用
/// 版式，兩處呼叫端只有文案與實際 RPC 不同（`DiaryDeleteConfirmationSheet`／
/// `CommentDeleteConfirmationSheet` 各自組好文案與呼叫後轉呼叫這裡，見兩檔）。
///
/// **不承諾可還原**（LS-152 Notes IN-1 裁決）：`bodyText` 一律用「這個動作目前無法在 App 內
/// 復原」收尾，不寫「30 天內可還原」——本畫面群刻意沒有還原入口。
///
/// **Grabber 自畫**，同 `LegalDocumentSheet`／`UploadQueueSheetView` 既有理由（LS-167／
/// LS-191）：系統 `.presentationDragIndicator` 會被 `tap-target-check.sh` 判成獨立
/// accessibility 元件（label「表單控點」，量到 76×25pt）、判成 <44pt 違規；改用純
/// `Shape`＋`.accessibilityHidden(true)`，drag-to-dismiss 手勢不受影響（系統行為）。
///
/// **高度改用 `.medium`／`.large` 兩級 detent＋內部 `ScrollView`**（LS-190 R2，merge-review R1
/// B1 blocker）：R1 版用 `GeometryReader` 在 `.background` 自我量測內容高度餵回
/// `presentationDetents([.height(_:)])`，是循環相依——`GeometryReader` 量到的其實是「已經被
/// 當下 detent 夾擠過」的高度（`measured = min(intrinsic, detent)`），`intrinsic > detent` 時
/// 永遠等於當下 detent、每次只能 `+8` 慢爬，追不上放大字級真正需要的高度。reviewer 實測
/// `extra-extra-extra-large`／`accessibility-extra-large`（AX3）／`accessibility-extra-
/// extra-extra-large`（AX5）三個字級下確認文案（含 IN-1 那句「這個動作目前無法在 App 內
/// 復原」）被截斷、按鈕擠在一起。改用系統原生的 `[.medium, .large]` 兩級 detent（不用任何自我
/// 量測），標題與內文放進 `ScrollView`——一般字級下 `.medium` 已經放得下全部內容（不太需要
/// 捲動）；字級放大到內容超出 `.medium` 高度時使用者可以捲動閱讀，或把 sheet 拉到 `.large`；
/// `.presentationContentInteraction(.scrolls)` 讓在內容區起手的手勢優先觸發捲動而不是把整張
/// sheet 往上拖（抓在 grabber／標題以外會拖動 sheet 本身，這是系統既有行為）。**兩顆按鈕與
/// 錯誤列固定在 `ScrollView` 之外**（底部釘住，不隨內容捲動）：任何字級下都維持宣告的
/// `minHeight`、絕不因為被 detent 夾擠而裁切熱區或跟內文擠在一起——R1 那個「WDA 量到的
/// hit-test 比宣告值少 2pt」其實就是這個 bug 的症狀（sheet 被夾擠到剛好卡在按鈕邊緣），不是
/// 量測工具的偏移，這裡拿掉當時繞症狀用的 `+8` 緩衝與 `minHeight: 52`，改回單純的
/// `minHeight: 48`（LS-95 長輩硬約束 ≥44pt 再加一點緩衝）。
///
/// **`ScrollView` 補 `.clipped()`**（LS-190 R3，merge-review R2 m6 PLAUSIBLE）：AX5 捲動到
/// 頂端只剩一行被截斷可見時，reviewer 回報那一行文字疊在 grabber 膠囊上、字看起來重影／模糊
/// （`LS-190-r3-m6-scrolled-full.png`）。實測重現：`xcrun simctl io screenshot` 在捲動後、
/// 靜止數秒仍看得到同樣的重影，不是捲動慣性動畫的暫態殘影。`ScrollView` 預設應該會把內容裁在
/// 自己的邊界內，這裡加一個明確的 `.clipped()`（不依賴預設行為）後重現同一個位置，重影消失、
/// 被截斷的那一行文字乾淨可讀（`LS-190-r3-m6-clipped-attempt.png`）——確切成因（`ScrollView`
/// 在這個組合下預設裁切為何不夠）未進一步查證，但這個修法本身風險低（只是把隱含的裁切行為
/// 明確化），且日記／留言兩個變體、AX3／AX5 皆已實測確認無回歸。
struct DeleteConfirmationSheet: View {
    let headTitle: String
    let bodyText: String
    let confirmLabel: String
    /// LS-189：封鎖確認（`BlockConfirmSheet`，稿 `EXgzz`，icon `user-x`→`person.fill.xmark`）與
    /// Owner 移除內容確認（`OwnerRemoveContentConfirmSheet`，稿 `WIyj9`，icon
    /// `trash-2`→`trash`）重用這支通用確認卡，只有 icon 跟原本的「刪除」不同——預設值
    /// `"trash"` 讓既有兩個呼叫端（`DiaryDeleteConfirmationSheet`／`CommentDeleteConfirmationSheet`）
    /// 完全不用改。
    var confirmIcon: String = "trash"
    /// 呼叫實際 RPC；不在這裡處理「成功之後」的畫面收尾（本地移除、pop 上一層…）——那些交給
    /// `onSuccess`，且保證在這個 sheet 自己的 `dismiss()` 之後才呼叫（LS-190 R2 m3，見下）。
    let confirmAction: () async throws -> Void
    /// RPC 成功、sheet 已經開始關閉之後才呼叫（LS-190 R2 m3，merge-review R1）：R1 版是呼叫端
    /// 的 `onDeleted` 閉包自己（例如 `DiaryDetailView`）先做本地移除＋`dismiss()`（pop 上一層）
    /// ，這個 sheet 才輪到呼叫自己的 `dismiss()`——等於先拆掉 sheet 的 presenter 再關 sheet，
    /// 且資料一被本地移除，`.sheet` 內容的 `if let` 分支可能立刻變空、`presentationDetents`
    /// 跟著消失。改成「這裡先 `dismiss()` 關掉自己，再呼叫 `onSuccess`」，順序反過來。
    var onSuccess: () -> Void = {}
    /// LS-189 R2（merge-review R1 B4）：`BlockConfirmSheet`／`UnblockConfirmSheet`／
    /// `OwnerRemoveContentConfirmSheet` 重用這支通用確認卡，但下方預設的 `userFacingMessage(for:)`
    /// 是為「刪除」量身寫的文案（42501→「你沒有權限刪除這項內容。」）——封鎖／解除封鎖的
    /// 42501 實際語意是「你已經不是這個家庭的成員」（`docs/API.md` §4 `block_user`），畫面卻說
    /// 「沒有權限刪除」，動詞完全錯。非 nil 時整支取代預設映射（不是疊加），呼叫端各自依自己
    /// 的動作語意給對應文案；nil（預設）維持既有兩個「刪除」呼叫端
    /// （`DiaryDeleteConfirmationSheet`／`CommentDeleteConfirmationSheet`）完全不用改。
    var errorCopy: ((AppError) -> String)?

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var error: AppError?

    var body: some View {
        VStack(spacing: 0) {
            grabber
            ScrollView {
                VStack(spacing: AppSpacing.block) {
                    Text(headTitle)
                        .appFont(.lead, weight: .bold)
                        .foregroundStyle(Color.lsTextPrimary)
                        .multilineTextAlignment(.center)
                    Text(bodyText)
                        .appFont(.note)
                        .foregroundStyle(Color.lsTextPrimary)
                }
                .padding(.horizontal, AppSpacing.screenPad)
                .padding(.top, AppSpacing.tight)
                .padding(.bottom, AppSpacing.block)
                .frame(maxWidth: .infinity)
            }
            .clipped()
            VStack(spacing: AppSpacing.group) {
                confirmButton
                cancelButton
                if let error {
                    errorRow(error)
                }
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.group)
            .padding(.bottom, AppSpacing.section)
        }
        .background(Color.lsSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.lsBorder)
            .frame(width: 36, height: 5)
            .padding(.top, AppSpacing.block)
            .padding(.bottom, AppSpacing.tight)
            .accessibilityHidden(true)
    }

    private var confirmButton: some View {
        Button(action: confirmTapped) {
            HStack(spacing: AppSpacing.label) {
                if isSubmitting {
                    ProgressView().tint(Color.lsDanger)
                } else {
                    Image(systemName: confirmIcon).appIconFrame(.medium)
                }
                Text(confirmLabel).appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsDanger)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.radiusMedium)
                    .strokeBorder(Color.lsDanger, lineWidth: 1.5)
            )
        }
        .disabled(isSubmitting)
    }

    private var cancelButton: some View {
        Button(action: cancelTapped) {
            Text("取消")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(isSubmitting)
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(userFacingMessage(for: error)).appFont(.note)
        }
        .foregroundStyle(Color.lsDanger)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// LS-190 R2 m2（merge-review R1）：R1 版一律用 `error.userFacingMessage`（「無法完成這個
    /// 操作。」），票文範圍 3 要求的「錯誤碼映射」EULA 那半邊做了（LS055／LS056）、這半邊沒做。
    /// 三個可達碼依 `docs/API.md` §5 與 LS-152 Notes `B9jlgF`（LS027 講的是「別人已經移除這則
    /// 內容」，跟 10/10b 自己的「無法在 App 內復原」文案鍵不共用，不能混用同一句話）給獨立文案；
    /// 訊息刻意不寫死「日記」或「留言」——這支 sheet 兩種內容共用，交給呼叫端的
    /// `headTitle`／`bodyText` 已經講清楚是哪一種。
    private func userFacingMessage(for error: AppError) -> String {
        if let errorCopy { return errorCopy(error) }
        guard case .rejected(_, let code) = error else { return error.userFacingMessage }
        switch code {
        case "42501":
            return "你沒有權限刪除這項內容。"
        case LSErrorCode.removedByOwnerNotRestorable.rawValue: // LS027
            return "這項內容已經被家庭管理者移除，只有管理者能還原。"
        case LSErrorCode.diaryNotFoundOrDeleted.rawValue, // LS020
             LSErrorCode.commentNotFound.rawValue: // LS024
            return "這項內容已經不存在，可能已經被刪除。"
        default:
            return error.userFacingMessage
        }
    }

    /// LS-190 R2 m1（merge-review R1）：`guard !isSubmitting` 同 `EULAStore` 系列既有慣例，
    /// 擋連點（VoiceOver 雙擊、Switch Control、自動化）在同一個 runloop 內排出兩個 `Task`。
    private func confirmTapped() {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await confirmAction()
                // LS-190 R2 m3：先關自己這張 sheet，再讓呼叫端做本地移除／pop——見
                // `onSuccess` 文件註解。
                dismiss()
                onSuccess()
            } catch {
                self.error = AppError.map(error)
            }
        }
    }

    private func cancelTapped() {
        dismiss()
    }
}
