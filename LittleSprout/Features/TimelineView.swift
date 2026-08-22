import SwiftUI

/// Placeholder：時間軸（Phase 1-5 實作）。
struct TimelineView: View {
    var body: some View {
        ContentUnavailableView(
            "時間軸",
            systemImage: "clock",
            description: Text("家庭的新相簿、照片與日記會在這裡依時間倒序混排。")
        )
    }
}

#Preview {
    NavigationStack { TimelineView() }
}
