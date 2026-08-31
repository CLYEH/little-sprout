import SwiftUI

/// 時間軸（Phase 1-5 實作，仍是 placeholder）＋ LS-113 寶貝切換器（10／10b）。
///
/// 時間軸本身（照片／日記混排、FAB、底部 Tab Bar）不在 LS-113 範圍——`ChildFilterBar`
/// 是這張票唯一要落地的部分，見該檔文件註解。選中的寶貝目前不會過濾任何內容（沒有真正的
/// 時間軸資料可以過濾），純粹是元件本身可操作、可測試。
struct TimelineView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore

    @State private var selectedChildID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !childrenStore.activeChildren.isEmpty {
                ChildFilterBar(childrenStore: childrenStore, selectedChildID: $selectedChildID)
                    .padding(.horizontal, AppSpacing.screenPad)
                    .padding(.top, AppSpacing.label)
            }
            ContentUnavailableView(
                "時間軸",
                systemImage: "clock",
                description: Text("家庭的新相簿、照片與日記會在這裡依時間倒序混排。")
            )
        }
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await childrenStore.refresh(familyID: familyID)
        }
    }
}

#Preview {
    NavigationStack { TimelineView(familyStore: .preview(), childrenStore: .preview()) }
}
