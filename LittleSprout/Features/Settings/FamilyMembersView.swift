import SwiftUI

/// 家庭成員管理（LS-24，尚未實作）——LS-188 只建立最小佔位，讓 01 設定頁「家庭成員」
/// （成員清單＋角色、Owner 管理成員）與「退出家庭」兩顆入口先接通同一個未來畫面（票文範圍：
/// 「Owner：管理成員 → 03 頁，另票」；LS-24 涵蓋「多 owner 轉移」，退出家庭與成員管理是
/// 同一個未來流程的一部分，稿面沒有另外拆一支「退出家庭」佔位檔）。LS-24 只會替換這個檔案的
/// 內容，不會動 root（見 `SettingsView` 文件註解）。
struct FamilyMembersView: View {
    var body: some View {
        ContentUnavailableView(
            "家庭成員",
            systemImage: "person.2.fill",
            description: Text("成員清單、角色管理與退出家庭尚未推出，敬請期待。")
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FamilyMembersView()
    }
}
#endif
