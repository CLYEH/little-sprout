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
            // `ContentUnavailableView(label:description:actions:)` 的 actions 插槽在本畫面的
            // 容器組合下（`RootView → AuthenticatedRootView → SectionTabView →
            // SectionContentView`）確實會渲染（R2 handoff 原先寫「完全不渲染」不夠精確，
            // R3 review B6 指出後重新量測更正）；但實測與 description 只隔約 20pt，視覺上
            // 像 description 段落的延伸而非獨立動作（`.claude/evidence/LS-17/r3/
            // b6-settings-before-production-hierarchy.png`，iPhone 17 Pro／iOS 26.0.1）。
            // 改用手排版面後，`ContentUnavailableView` 只剩 label/description 兩段、不再
            // 用 `.frame(maxHeight: .infinity)` 把整個 VStack 撐滿，登出鈕因此落在畫面下段、
            // 與說明文字明顯分開（同目錄 `b6-settings-after-production-hierarchy.png`）。
            ContentUnavailableView {
                Label("設定", systemImage: "gearshape")
            } description: {
                Text("家庭管理、成員邀請與帳號設定會顯示在這裡。")
            }
            // LS-17 QA1：原 `Button("登出", role: .destructive, action: signOut)` 實測
            // 32×19pt，違反長輩硬約束 ≥44pt 點擊目標。改用 label closure 加不可見 padding
            // 撐大點擊區，視覺仍是純文字紅字、不加框、不改樣式。
            Button(role: .destructive, action: signOut) {
                Text("登出")
                    .padding(.vertical, AppSpacing.item)
                    .padding(.horizontal, AppSpacing.item)
                    .contentShape(Rectangle())
            }
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
