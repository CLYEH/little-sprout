import SwiftUI

/// 封鎖名單（LS-23，尚未實作）——LS-188 只建立最小佔位，讓 01 設定頁「內容與安全」區
/// 「封鎖名單」列的 `NavigationLink` 先接通。LS-23 只會替換這個檔案的內容，不會動 root（見
/// `SettingsView` 文件註解）。
struct BlockListView: View {
    var body: some View {
        ContentUnavailableView(
            "封鎖名單",
            systemImage: "person.fill.xmark",
            description: Text("封鎖名單尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        BlockListView()
    }
}
#endif
