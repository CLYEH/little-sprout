import SwiftUI

/// 檢舉收件匣（LS-23，尚未實作，Owner 限定）——LS-188 只建立最小佔位，讓 01 設定頁
/// 「內容與安全」區「檢舉紀錄」列的 `NavigationLink` 先接通。LS-23 只會替換這個檔案的內容，
/// 不會動 root（見 `SettingsView` 文件註解）——包含這顆列只在 Owner 才顯示的判斷（`childrenStore
/// .isOwner`）。
struct ReportInboxView: View {
    var body: some View {
        ContentUnavailableView(
            "檢舉紀錄",
            systemImage: "flag.fill",
            description: Text("檢舉收件匣尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ReportInboxView()
    }
}
#endif
