import SwiftUI

/// 顯示名稱與頭像編輯（LS-152 「02」頁，尚未實作）——LS-188 只建立最小佔位，讓 01 設定頁
/// 「個人」列的 `NavigationLink` 先接通。02 頁票只會替換這個檔案的內容，不會動 root（見
/// `SettingsView` 文件註解）。
struct ProfileEditView: View {
    var body: some View {
        ContentUnavailableView(
            "顯示名稱與頭像",
            systemImage: "person.crop.circle",
            description: Text("編輯顯示名稱與頭像尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ProfileEditView()
    }
}
#endif
