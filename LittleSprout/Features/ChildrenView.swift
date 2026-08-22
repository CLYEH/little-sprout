import SwiftUI

/// Placeholder：孩子檔案（Phase 1-3 實作）。
struct ChildrenView: View {
    var body: some View {
        ContentUnavailableView(
            "孩子",
            systemImage: "figure.and.child.holdinghands",
            description: Text("孩子的檔案與年齡標記會顯示在這裡。")
        )
    }
}

#Preview {
    NavigationStack { ChildrenView() }
}
