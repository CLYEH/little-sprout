import SwiftUI

/// Placeholder：設定（家庭管理、成員、帳號）。
///
/// 登出鈕是本畫面目前唯一可用的動作（LS-17 R2 review N7）：家庭管理／成員邀請等其餘功能仍是
/// 占位，但完全沒有登出入口，QA 在 test branch 驗收時要重測 Email OTP 只能刪 app 重裝——
/// `AuthStore.signOut()` 已實作並測過，成本很低，先接上這一顆。
struct SettingsView: View {
    let authStore: AuthStore

    @State private var isSigningOut = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: AppSpacing.block) {
            // `ContentUnavailableView(label:description:actions:)` 的 actions 插槽在本專案
            // 用的 iOS 版本上實測不會渲染（模擬器手動點過，accessibility tree 也看不到）——
            // 改用手排版面，登出鈕才是真的按得到的（LS-17 R2 review N7）。
            ContentUnavailableView {
                Label("設定", systemImage: "gearshape")
            } description: {
                Text("家庭管理、成員邀請與帳號設定會顯示在這裡。")
            }
            Button("登出", role: .destructive, action: signOut)
                .disabled(isSigningOut)
        }
        .alert(
            "登出失敗",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            do {
                try await authStore.signOut()
            } catch {
                errorMessage = AppError.map(error).userFacingMessage
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsView(authStore: .preview()) }
}
