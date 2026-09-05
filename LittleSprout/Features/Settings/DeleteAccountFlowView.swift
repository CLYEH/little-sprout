import SwiftUI

/// 刪除帳號流程（LS-24，尚未實作）——LS-188 只建立最小佔位，讓 01 設定頁「帳號」區「刪除
/// 帳號」列的 `NavigationLink` 先接通。LS-24 只會替換這個檔案的內容，不會動 root（見
/// `SettingsView` 文件註解）。
struct DeleteAccountFlowView: View {
    var body: some View {
        ContentUnavailableView(
            "刪除帳號",
            systemImage: "trash",
            description: Text("刪除帳號流程尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DeleteAccountFlowView()
    }
}
#endif
