import SwiftUI

/// 依 horizontal size class 切換版面的根視圖。
///
/// selection 存在這一層而非各自的子視圖，所以 iPad 旋轉／分割畫面造成 size class
/// 改變時，使用者停留的區塊會被保留。
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection = .timeline

    var body: some View {
        if horizontalSizeClass == .compact {
            SectionTabView(selection: $selection)
        } else {
            SectionSplitView(selection: $selection)
        }
    }
}

/// Compact（iPhone 直向）：四分頁 TabView。
private struct SectionTabView: View {
    @Binding var selection: AppSection

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    SectionContentView(section: section)
                }
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(section)
            }
        }
    }
}

/// Regular（iPad、iPhone 橫向 Max）：sidebar 列四區塊的 NavigationSplitView。
private struct SectionSplitView: View {
    @Binding var selection: AppSection

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle("Little Sprout")
        } detail: {
            NavigationStack {
                SectionContentView(section: selection)
            }
        }
    }

    /// `List` 的單選 API 只接受 optional binding；取消選取（nil）時保持原區塊，
    /// 否則 detail 會變成空白畫面。
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection },
            set: { selection = $0 ?? selection }
        )
    }
}

/// 兩種版面共用的內容切換器，確保 compact／regular 顯示的是同一組畫面。
struct SectionContentView: View {
    let section: AppSection

    var body: some View {
        content
            .navigationTitle(section.title)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .timeline: TimelineView()
        case .albums: AlbumsView()
        case .children: ChildrenView()
        case .settings: SettingsView()
        }
    }
}

#Preview("Compact") {
    RootView()
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Regular") {
    RootView()
        .environment(\.horizontalSizeClass, .regular)
}
