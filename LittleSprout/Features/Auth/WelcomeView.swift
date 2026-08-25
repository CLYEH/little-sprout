import AuthenticationServices
import SwiftUI

/// LS-17 / 01 歡迎登入（含 01b 登入中、01c 深色模式、01-iPad、AX3 變體）。
///
/// 版式依 `.claude/evidence/LS-17/spec/`（LS-46 R11 進場條件）：B 版式蠟筆字標、深色模式
/// 字標＋Tagline 搬到相片上緣的紙條上、Apple 為主要動作、Google 為 stub、Email 為次要動作。
struct WelcomeView: View {
    let authStore: AuthStore

    @State private var path: [AuthRoute] = []
    @State private var isSigningInWithApple = false
    @State private var appleErrorMessage: String?
    @State private var isGoogleStubAlertPresented = false
    @State private var currentAppleNonce: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

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
        .alert("Google 登入即將推出", isPresented: $isGoogleStubAlertPresented) {
            Button("好", role: .cancel) {}
        }
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            printStageSection
            VStack(alignment: .leading, spacing: 0) {
                headSection
                Spacer(minLength: 0)
                actionsSection
                    .padding(.top, AppSpacing.item)
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
            printStageSection
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                headSection
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
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

    private var printStageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if colorScheme == .dark {
                wordmarkPaperStrip
            }
            PrintPhotoCard(accessibilityLabel: "祖母抱著嬰兒在晨光中的合照")
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
            .frame(width: 190, height: 91)
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

    private var actionsSection: some View {
        VStack(spacing: AppSpacing.label) {
            AppleSignInButton(
                isSigningIn: isSigningInWithApple,
                onRequest: configureAppleRequest,
                onCompletion: handleAppleCompletion
            )
            GoogleSignInButton(isDimmed: isSigningInWithApple) {
                isGoogleStubAlertPresented = true
            }
            .padding(.top, 4)
            SecondaryButton(icon: "envelope", title: "使用 Email 登入", isDimmed: isSigningInWithApple) {
                path.append(.emailInput)
            }
            .padding(.top, AppSpacing.group)
        }
    }

    @ViewBuilder
    private var legalOrStatusSlot: some View {
        if isSigningInWithApple {
            Text("正在與 Apple 確認你的身分，請稍候。")
                .appFont(.note)
                .foregroundStyle(Color.lsTextPrimary)
        } else {
            Text(legalAttributedString)
                .appFont(.meta)
        }
    }

    private var legalAttributedString: AttributedString {
        var intro = AttributedString("登入即表示你同意")
        intro.foregroundColor = .lsTextSecondary

        var terms = AttributedString("《使用條款》")
        terms.foregroundColor = .lsTextPrimary
        terms.underlineStyle = .single
        terms.link = URL(string: "https://littlesprout.app/legal/terms")

        var and = AttributedString("與")
        and.foregroundColor = .lsTextSecondary

        var privacy = AttributedString("《隱私權政策》")
        privacy.foregroundColor = .lsTextPrimary
        privacy.underlineStyle = .single
        privacy.link = URL(string: "https://littlesprout.app/legal/privacy")

        return intro + terms + and + privacy
    }

    // MARK: - Sign in with Apple

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleSignInNonce.randomNonce()
        currentAppleNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = AppleSignInNonce.sha256(nonce)
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
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
