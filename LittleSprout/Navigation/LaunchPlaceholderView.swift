import SwiftUI

/// LS-502：冷啟動「還原中」（`RootRoute.restoring`）顯示的啟動佔位頁。
///
/// 非功能畫面（無文字按鈕、無互動元件；與 `FamilyLookupFailedView`／EULA 閘門同類，不是新畫面
/// 設計）：`appBackground()` 底色＋置中字標。字標沿用 `WelcomeView` 同一份 `Wordmark` 資產，
/// 純裝飾，對 VoiceOver 隱藏——這一頁最長只停留數秒（`AuthStore.restoreTimeout`）。
struct LaunchPlaceholderView: View {
    var body: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(width: 190, height: 91)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appBackground()
    }
}

#if DEBUG
#Preview {
    LaunchPlaceholderView()
}
#endif
