import SwiftUI

/// 時間軸（Phase 1-5 實作，仍是 placeholder）＋ LS-113 寶貝切換器（10／10b）。
///
/// 時間軸本身（照片／日記混排、FAB、底部 Tab Bar）不在 LS-113 範圍——`ChildFilterBar`
/// 是這張票唯一要落地的部分，見該檔文件註解。選中的寶貝目前不會過濾任何內容（沒有真正的
/// 時間軸資料可以過濾），純粹是元件本身可操作、可測試。
///
/// LS-125：導覽列右側暫時的「+」鈕是`DiaryEditorView`（日記編輯器）唯一入口——正式的建立
/// 入口（FAB 或釘底動作帶，見 `design/littlesprout.pen` Handoff Notes `pUlmx`／`kh7Xw` 的
/// 例外論證）是時間軸本身的範圍（LS-126），本票只需要一個能在模擬器打開編輯器的路徑，不做
/// 版面設計；LS-126 落地正式入口時這顆暫時按鈕應該被移除或替換。
struct TimelineView: View {
    let familyStore: FamilyStore
    let childrenStore: ChildrenStore
    let diaryAPIClient: DiaryAPIClient
    let mediaUploadService: MediaUploadService

    @State private var selectedChildID: UUID?
    @State private var showsDiaryEditor = false

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
        .toolbar {
            if familyStore.myFamily != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsDiaryEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("寫日記")
                }
            }
        }
        .navigationDestination(isPresented: $showsDiaryEditor) {
            if let familyID = familyStore.myFamily?.id {
                DiaryEditorView(
                    familyID: familyID, diaryAPIClient: diaryAPIClient, mediaUploadService: mediaUploadService,
                    childrenStore: childrenStore
                )
            }
        }
        .task(id: familyStore.myFamily?.id) {
            guard let familyID = familyStore.myFamily?.id else { return }
            await childrenStore.refresh(familyID: familyID)
        }
    }
}

#Preview {
    NavigationStack {
        TimelineView(
            familyStore: .preview(), childrenStore: .preview(),
            diaryAPIClient: PreviewDiaryAPIClient(), mediaUploadService: PreviewMediaUploadService()
        )
    }
}
