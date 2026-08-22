import SwiftUI

/// Placeholder：設定（家庭管理、成員、帳號）。
struct SettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "設定",
            systemImage: "gearshape",
            description: Text("家庭管理、成員邀請與帳號設定會顯示在這裡。")
        )
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
