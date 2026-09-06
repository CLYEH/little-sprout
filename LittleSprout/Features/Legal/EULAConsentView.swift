import SwiftUI

/// LS-190（依 LS-152 稿 `z042Yg`／`rh2Q1`；Notes MN-1「家庭管理者」詞彙定案）：EULA 同意頁。
/// 首次登入（無同意紀錄）或條款版本更新時強制出現——由 `RootView.AuthenticatedGate` 依
/// `EULAStore.shouldPresent` 決定要不要顯示這個畫面，取代原本的家庭查詢／主畫面，不可下滑
/// 關閉（本畫面不是 sheet，是取代整個已登入畫面樹的一般畫面內容）。
///
/// **零容忍條款摘要是 app 內建靜態文案**，不從伺服器抓——`app_settings.eula_version` 只是一個
/// 不透明的版本標籤（用來比對「使用者是否已同意目前這份文案」），本畫面的四點摘要文字固定寫死
/// 在這裡，版本 bump 不會改變這裡顯示的文字（法務文本正式內容見 LS-132／`docs/legal/`，全文
/// 入口見下方「查看完整」連結開 `LegalDocumentSheet`）。
///
/// **全文入口沿用 `LegalDocumentSheet`**（LS-191 已在 development）：同 `WelcomeView+Legal`
/// 的既有技巧——用自訂 `legalsheet://` scheme 包成兩個獨立連結（《使用條款》／《隱私權政策》），
/// `.environment(\.openURL, ...)` 攔截後開 `LegalDocumentSheet(kind:)`，不是真的打開網址。
///
/// **「不同意」出口是本票補的最小實作，非稿面內容**（LS-152 IN-1 追蹤：「EULA 首次登入態＋
/// 不同意出口」列在 R2 INFO、未列入 VR 必做清單，稿面 `z042Yg`／`rh2Q1` 只畫了「我已閱讀並
/// 同意」這一顆實心鈕，沒有畫拒絕動作）——票文明文要求「不同意 → 登出回歡迎頁」是功能性需求，
/// 借用本設計系統既有的 `cmp/Button Text` 純文字次要動作語彙（同「取消」／「之後再說」的視覺
/// 家族）補上，不是自創新視覺語言。**merge-review R1 裁定不退修**（`minHeight: 48` 達標、
/// 票文明文要求、視覺合理），排入 LS-208 補這一顆的稿面變體，不擋本票併入。
///
/// **首次登入時仍顯示「使用條款更新」／「我們更新了《使用條款》」**（merge-review R1 m4，
/// PLAUSIBLE，裁定不修）：逐字對稿 `z042Yg`（`p1Y1H4`／`hSVAP`）完全相符——稿面只畫了「版本
/// 更新」這個情境，LS-152 Notes 沒有把「首次登入」的文案變體列進 VR 必做清單。對第一次註冊、
/// 從未見過任何條款的使用者而言這句話字面上不精確，但這是**稿的缺口**、不是本票實作偏離稿面
/// ——排入 LS-208 範圍 7（08 首次登入變體），本票不越權自己另外設計一套文案。
struct EULAConsentView: View {
    let eulaStore: EULAStore
    /// 「不同意」的收尾——登出＋清空各 store 本地狀態，由持有那些 store 的呼叫端
    /// （`RootView.AuthenticatedGate`）實作，本畫面不直接依賴 `FamilyStore`／`ChildrenStore`／
    /// `TimelineStore`／`AlbumsStore`。`async throws`：登出失敗（少見，例如網路問題）時本畫面
    /// 顯示錯誤、留在原地，不是靜默無反應（票文「不同意 → 留在頁面／登出」涵蓋的兩種結果）。
    let onDisagree: () async throws -> Void

    @State private var presentedLegalDocument: LegalDocumentKind?
    @State private var isDisagreeing = false
    @State private var disagreeError: AppError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                zeroToleranceCard
                    .padding(.top, AppSpacing.section)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.block)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .appBackground()
        .sheet(item: $presentedLegalDocument) { kind in
            LegalDocumentSheet(kind: kind)
        }
        .environment(\.openURL, legalLinkOpenURLAction)
    }

    // MARK: - Header／零容忍卡

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.label) {
            Text("使用條款更新")
                .appFont(.display, weight: .bold)
                .foregroundStyle(Color.lsTextPrimary)
            Text("我們更新了《使用條款》。在繼續使用萌芽日記之前，請看一下最重要的一段。")
                .appFont(.body)
                .foregroundStyle(Color.lsTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zeroToleranceCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.block) {
            HStack(spacing: AppSpacing.label) {
                Image(systemName: "exclamationmark.shield.fill").appIconFrame(.medium)
                Text("對冒犯性內容零容忍").appFont(.body, weight: .bold)
            }
            .foregroundStyle(Color.lsTextPrimary)

            point("色情、暴力、騷擾、歧視、侵害他人隱私的內容一律禁止；情節重大者會永久停權，涉及未成年人安全的內容會依法通報。")
            point("任何家庭成員都能在 App 內檢舉，我們與家庭管理者都會處理，並在收到後 24 小時內採取行動。")
            point("你可以封鎖任何成員；對方不會收到通知，也不會受到任何影響。")
            point("家庭管理者可以移除違規內容、移除成員，並處理家庭內的檢舉。")
        }
        .padding(AppSpacing.insetCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lsSurface)
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.radiusLarge)
                .strokeBorder(Color.lsBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.radiusLarge))
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.group) {
            Circle()
                .fill(Color.lsTextSecondary)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
        }
    }

    // MARK: - Action Bar（釘底）

    private var actionBar: some View {
        VStack(spacing: AppSpacing.label) {
            Rectangle().fill(Color.lsBorder).frame(height: 1)
            VStack(spacing: AppSpacing.label) {
                Text(legalLinkAttributedString)
                    .appFont(.note, weight: .semibold)
                PrimaryButton(
                    icon: "checkmark",
                    title: "我已閱讀並同意",
                    isLoading: eulaStore.acceptState.isSubmitting,
                    loadingTitle: "正在紀錄同意…",
                    action: agreeTapped
                )
                if case .failure(let error) = eulaStore.acceptState {
                    errorRow(error)
                }
                if let disagreeError {
                    errorRow(disagreeError)
                }
                disagreeButton
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.bottom, AppSpacing.item)
        }
        .background(Color.lsSurface)
    }

    /// LS-152 IN-1 追蹤（見型別文件註解）：稿面沒有畫這顆鈕，借用既有 `cmp/Button Text`
    /// 語彙補上功能性需求。
    private var disagreeButton: some View {
        Button(action: disagreeTapped) {
            Text("不同意，登出")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(Color.lsTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(isDisagreeing || eulaStore.acceptState.isSubmitting)
    }

    private func errorRow(_ error: AppError) -> some View {
        HStack(spacing: AppSpacing.tight) {
            Image(systemName: "exclamationmark.circle").appIconFrame(.small)
            Text(userFacingMessage(for: error)).appFont(.note)
        }
        .foregroundStyle(Color.lsDanger)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// LS-152 Notes 的錯誤文案鍵表定案於 LS-197（accept_eula）落地之前，沒有 LS055／LS056 的
    /// 專屬列——這裡直接照 `docs/API.md` §5 的表格文字給更明確的下一步動作，比
    /// `AppError.userFacingMessage` 的通用文案（「無法完成這個操作。」）更能引導長輩重試。
    private func userFacingMessage(for error: AppError) -> String {
        guard case .rejected(_, let code) = error else { return error.userFacingMessage }
        switch code {
        case LSErrorCode.eulaVersionMismatch.rawValue:
            return "條款版本已經更新，我們已經幫你抓到最新版本，請重新按一次「我已閱讀並同意」。"
        case LSErrorCode.accountProfileMissing.rawValue:
            return "帳號資料異常，請聯絡我們。"
        default:
            return error.userFacingMessage
        }
    }

    private func agreeTapped() {
        Task { await eulaStore.accept() }
    }

    private func disagreeTapped() {
        guard !isDisagreeing else { return }
        isDisagreeing = true
        disagreeError = nil
        Task {
            defer { isDisagreeing = false }
            do {
                try await onDisagree()
            } catch {
                disagreeError = AppError.map(error)
            }
        }
    }
}

// MARK: - 法務連結（同 `WelcomeView+Legal` 既有技巧）

private extension EULAConsentView {
    var legalLinkAttributedString: AttributedString {
        var prefix = AttributedString("查看完整")
        prefix.foregroundColor = .lsTextPrimary

        var terms = AttributedString("《使用條款》")
        terms.foregroundColor = .lsTextPrimary
        terms.underlineStyle = .single
        terms.link = LegalDocumentKind.termsOfService.linkURL

        var and = AttributedString("與")
        and.foregroundColor = .lsTextPrimary

        var privacy = AttributedString("《隱私權政策》")
        privacy.foregroundColor = .lsTextPrimary
        privacy.underlineStyle = .single
        privacy.link = LegalDocumentKind.privacyPolicy.linkURL

        return prefix + terms + and + privacy
    }

    var legalLinkOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let kind = LegalDocumentKind(linkURL: url) else { return .systemAction }
            presentedLegalDocument = kind
            return .handled
        }
    }
}

#if DEBUG
#Preview("首次登入") {
    EULAConsentView(eulaStore: .preview(shouldPresent: true), onDisagree: {})
}
#endif
