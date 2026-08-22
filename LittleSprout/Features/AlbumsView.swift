import SwiftUI

/// Placeholder：相簿（Phase 1-4 實作）。
struct AlbumsView: View {
    var body: some View {
        ContentUnavailableView(
            "相簿",
            systemImage: "photo.on.rectangle.angled",
            description: Text("依日期整理的照片與影片相簿會顯示在這裡。")
        )
    }
}

#Preview {
    NavigationStack { AlbumsView() }
}
