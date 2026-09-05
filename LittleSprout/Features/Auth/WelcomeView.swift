import AuthenticationServices
import SwiftUI

/// LS-17 / 01 歡迎登入（含 01b 登入中、01c 深色模式、01-iPad、AX3 變體）。
///
/// 版式依 `.claude/evidence/LS-17/spec/`（LS-46 R11 進場條件）：B 版式蠟筆字標、深色模式
/// 字標＋Tagline 搬到相片上緣的紙條上、Apple 為主要動作、Google 為次要動作（LS-39 起接真流程，
/// 不再是 stub）、Email 為次要動作。
struct WelcomeView: View {
    let authStore: AuthStore

    // 非 private：`WelcomeView+PasswordSignIn.swift`（LS-164）需要存取，同 `CreateChildView`
    // 的 `name`／`pickedAvatarPreview` 既有作法。
    @State var path: [AuthRoute] = []
    @State private var isSigningInWithApple = false
    @State private var appleErrorMessage: String?
    @State private var isSigningInWithGoogle = false
    @State private var googleErrorMessage: String?
    @State private var currentAppleNonce: String?
    // LS-191：歡迎頁法務連結改開 in-app sheet（取代原本跳出系統瀏覽器）——非 private：
    // `WelcomeView+Legal.swift` 的 `legalLinkOpenURLAction` 需要寫入這個狀態，同
    // `path`（`WelcomeView+PasswordSignIn.swift`）的既有作法。
    @State var presentedLegalDocument: LegalDocumentKind?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    // LS-39：presentation context 由 SwiftUI 環境提供（iOS 16+），不必自己寫
    // `ASWebAuthenticationPresentationContextProviding` 去找 key window。
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        NavigationStack(path: $path) {
            ScrollableFillView {
                Group {
                    if horizontalSizeClass == .regular {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
            }
            .appBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .emailInput:
                    EmailSignInView(authStore: authStore) { email in
                        path.append(.otpVerification(email: email))
                    }
                case .otpVerification(let email):
                    OTPVerificationView(email: email, authStore: authStore) {
                        path.removeAll()
                    }
                case .passwordSignIn:
                    PasswordSignInView(authStore: authStore) {
                        path.removeAll()
                    }
                }
            }
        }
        .alert(
            "無法使用 Apple 登入",
            isPresented: Binding(get: { appleErrorMessage != nil }, set: { if !$0 { appleErrorMessage = nil } }),
            presenting: appleErrorMessage
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "無法使用 Google 登入",
            isPresented: Binding(get: { googleErrorMessage != nil }, set: { if !$0 { googleErrorMessage = nil } }),
            presenting: googleErrorMessage
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(item: $presentedLegalDocument) { kind in
            LegalDocumentSheet(kind: kind)
        }
        .environment(\.openURL, legalLinkOpenURLAction)
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            printStageSection()
            VStack(alignment: .leading, spacing: 0) {
                headSection
                Spacer(minLength: 0)
                actionsSection
                    .padding(.top, AppSpacing.item)
                passwordSignInLink
                    .padding(.top, AppSpacing.label)
                legalOrStatusSlot
                    .padding(.top, AppSpacing.group)
            }
            .padding(.horizontal, AppSpacing.screenPad)
            .padding(.top, AppSpacing.section)
            .padding(.bottom, AppSpacing.item)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .center, spacing: AppSpacing.section) {
            // LS-98：01-iPad 稿面（`design/littlesprout.pen` frame `BDrtd`）的染料池四角光強度
            // ＝ `PrintPhotoCard.MountPoolOpacity.iPad`（LS-17 sweeper F1：這組值原本零呼叫點）。
            printStageSection(mountPoolOpacity: .iPad)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                headSection
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
                    passwordSignInLink
                        .padding(.top, AppSpacing.label)
                    legalOrStatusSlot
                        .padding(.top, AppSpacing.group)
                }
            }
            .frame(width: 320)
        }
        .padding(.horizontal, AppSpacing.screenPadLarge)
        .padding(.vertical, AppSpacing.section)
        .frame(maxWidth: .infinity, minHeight: 0)
    }

    // MARK: - Sections

    /// `mountPoolOpacity` 預設 `.welcome`（iPhone 01 板）；`.iPad` 是 `regularLayout` 專用
    /// （LS-98），台紙壓邊 token（`$print-edge`／`$print-edge-bottom`）兩板同值 8pt，不受此
    /// 參數影響。
    private func printStageSection(
        mountPoolOpacity: PrintPhotoCard.MountPoolOpacity = .welcome
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if colorScheme == .dark {
                wordmarkPaperStrip
            }
            PrintPhotoCard(
                mountPoolOpacity: mountPoolOpacity,
                imageName: "HeroGrandma",
                accessibilityLabel: "祖母抱著嬰兒在晨光中的合照"
            )
            .padding(.top, 5)
        }
        .padding(.horizontal, 16)
    }

    private var wordmarkPaperStrip: some View {
        VStack(spacing: AppSpacing.label) {
            wordmarkImage
            Text("給家人的私密相簿")
                .appFont(.body)
                .foregroundStyle(Color.lsPrintInkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .padding(.bottom, AppSpacing.label)
        .frame(maxWidth: .infinity)
        .background(Color.lsPrintPaper)
    }

    @ViewBuilder
    private var headSection: some View {
        if colorScheme == .light {
            VStack(alignment: .leading, spacing: AppSpacing.label) {
                wordmarkImage
                Text("給家人的私密相簿")
                    .appFont(.body)
                    .foregroundStyle(Color.lsTextSecondary)
                trustRow
            }
        } else {
            trustRow
        }
    }

    private var wordmarkImage: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(width: wordmarkSize.width, height: wordmarkSize.height)
            .accessibilityLabel("萌芽日記")
    }

    private var trustRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.label) {
            Image(systemName: "lock.fill")
                .appIconFrame(.small)
                .foregroundStyle(Color.lsTextSecondary)
            Text("只有你邀請的家人看得到")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // 三顆鈕間距一致（LS-101 point 1）：單一 VStack `spacing` token 是唯一的間距來源；
    // 舊版每顆鈕自身還疊加 `.padding(.top:)`（Google +4、Email +$sp-group），量測後段距
    // 分別是 12pt／20pt，並不等距。R1 review I1：三顆並列的頂層控制項語意上是一個 group，
    // 取 `AppSpacing.group`（12pt，`$sp-group`）而非 `AppSpacing.label`（8pt）——8pt 會把原本
    // 最小的那段（12pt）反而壓得更緊，卡到 HIG 相鄰點擊目標下限，對長輩是反方向；改後三段
    // 間距一致為 12pt，且不低於改動前任一段（見 handoff）。設計稿 01 板的 12／20 不等距回頭
    // 對齊本值，記 LS-96。
    private var actionsSection: some View {
        // 任一登入方式在跑（Apple 或 Google）都要讓另外兩顆鈕暫時不可按——只是「in-flight
        // disable」，不是驗證型 disable（elder-constraints 硬約束，見 OTPVerificationModel.
        // isLocked 註解）。R1 review F1：三顆鈕的互斥狀態集中在 `authButtonsState`（純值型別
        // `AuthButtonsState`，見檔尾 extension），跟 `legalOrStatusSlot` 共用同一份，避免兩處
        // 各自用 `isSigningInWithApple` 兜邏輯而漏掉其中一處（原 bug：Apple 鈕沒吃到 Google
        // 在跑時要 disable 的規則）。
        VStack(spacing: AppSpacing.group) {
            AppleSignInButton(
                isSigningIn: authButtonsState.appleShowsInFlight,
                isDisabled: authButtonsState.appleIsDisabled,
                onRequest: configureAppleRequest,
                onCompletion: handleAppleCompletion
            )
            GoogleSignInButton(isDimmed: authButtonsState.googleIsDimmed) {
                handleGoogleSignIn()
            }
            SecondaryButton(
                icon: "envelope",
                title: "使用 Email 登入",
                isDimmed: authButtonsState.emailIsDimmed
            ) {
                path.append(.emailInput)
            }
        }
    }

    // `passwordSignInLink`：見 `WelcomeView+PasswordSignIn.swift`（LS-164，拆到另一個檔案
    // 避免這個檔案超過 SwiftLint file_length 上限）。
    // `legalOrStatusSlot`／`legalAttributedString`／`legalLinkOpenURLAction`：見
    // `WelcomeView+Legal.swift`（LS-191，同一個拆檔理由）。

    // MARK: - Sign in with Apple

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.randomNonce()
        currentAppleNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

    // MARK: - Sign in with Google

    private func handleGoogleSignIn() {
        isSigningInWithGoogle = true
        Task {
            defer { isSigningInWithGoogle = false }
            do {
                try await authStore.signInWithGoogle { url in
                    // `callback:`（`ASWebAuthenticationSession.Callback`）版本要 iOS 17.4+；
                    // 專案部署目標是 17.0（project.yml），改用舊版 `callbackURLScheme:` 字串
                    // 多載（iOS 16+ 起可用，行為等價，只是還沒吃到 17.4 的新 Callback 型別）。
                    try await webAuthenticationSession.authenticate(
                        using: url,
                        callbackURLScheme: "littlesprout"
                    )
                }
            } catch {
                // 使用者在系統瀏覽器面板主動取消：跟 Apple 的 `.canceled` 分支同語意，
                // 靜默、不算失敗（見 `AuthService.signInWithGoogle` 協定文件）。判定抽成
                // `Self.isUserCanceledGoogleSignIn`（R1 review I2）：這條規則原本整段內嵌
                // 在 catch 分支裡，被整段誤刪也不會有測試變紅——抽出後這條判定本身有單元
                // 測試釘住（`AuthButtonsStateTests.swift`）。
                guard !Self.isUserCanceledGoogleSignIn(error) else { return }
                googleErrorMessage = AppError.map(error).userFacingMessage
            }
        }
    }
}

// MARK: - R1 review F1／I2、R2 review F1-A（PR #163）：抽成 extension 而不是塞進上面的
// struct body，是刻意避開 SwiftLint `type_body_length`（該 struct 本來就已經逼近上限，同檔案
// extension 的成員依 SE-0169 仍能存取 `private` 的 `@State` 屬性，計數卻是分開算的，同
// OTPVerificationModel 系列測試檔拆檔的理由——只是這裡拆的是 extension 不是檔案）。
extension WelcomeView {
    /// 三顆鈕互斥狀態的集中計算，見 `AuthButtonsState.swift`（純值型別，可單元測試，
    /// `actionsSection`／`legalOrStatusSlot`／`passwordSignInLink`（LS-164，
    /// `WelcomeView+PasswordSignIn.swift`）共用同一份，避免各自用 `isSigningInWithApple`
    /// 兜邏輯而漏掉其中一處；非 private 的理由同 `path`）。
    var authButtonsState: AuthButtonsState {
        AuthButtonsState(isSigningInWithApple: isSigningInWithApple, isSigningInWithGoogle: isSigningInWithGoogle)
    }

    /// LS-98：字標框尺寸依 size class 切換。iPad（`.regular`）用 01-iPad 稿面（frame `BDrtd`／
    /// 節點 `A6DnYR`）量到的 247×118（`AppSpacing.wordmarkWidthIPad`／`wordmarkHeightIPad`）；
    /// iPhone（`.compact`）維持 01 板原本內嵌的 190×91，不因此改成 token（不動 compact 版）。
    private var wordmarkSize: (width: CGFloat, height: CGFloat) {
        horizontalSizeClass == .regular
            ? (AppSpacing.wordmarkWidthIPad, AppSpacing.wordmarkHeightIPad)
            : (190, 91)
    }

    /// Google 登入面板「使用者主動取消」的判定：獨立、可測試的純函式（R1 review I2）。
    static func isUserCanceledGoogleSignIn(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }

    /// Apple `SignInWithAppleButton` 的 completion callback（R2 review F1-A：`.disabled()`
    /// 對官方鈕可能是 no-op，見 `AuthButtonsState.shouldAcceptAppleCompletion` 檔頭說明）。
    /// 開頭先過 model 層守門，任一其他方式在跑就整段提早 return——不動 `isSigningInWithApple`
    /// 旗標、不顯示錯誤 alert，使用者沒做錯事，只是官方鈕在別的方式跑的時候仍被點到。
    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        guard
            AuthButtonsState.shouldAcceptAppleCompletion(
                isSigningInWithGoogle: isSigningInWithGoogle,
                isNavigatingToEmail: !path.isEmpty
            )
        else { return }

        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentAppleNonce
            else {
                appleErrorMessage = "無法取得 Apple 登入憑證，請再試一次。"
                return
            }
            isSigningInWithApple = true
            Task {
                defer { isSigningInWithApple = false }
                do {
                    try await authStore.signInWithApple(idToken: idToken, nonce: nonce)
                } catch {
                    appleErrorMessage = AppError.map(error).userFacingMessage
                }
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            appleErrorMessage = AppError.map(error).userFacingMessage
        }
    }
}

#if DEBUG
#Preview("Light") {
    WelcomeView(authStore: .preview())
}

#Preview("Dark") {
    WelcomeView(authStore: .preview())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    WelcomeView(authStore: .preview())
        .dynamicTypeSize(.accessibility3)
}
#endif
