import SwiftUI

/// 「窗光」漸層（Tokens 板「② 漸層」①）：每個登入畫面根層的背景。
struct AppBackground: View {
    var body: some View {
        RadialGradient(
            colors: [Color.lsBackgroundLit, Color.lsBackground],
            center: UnitPoint(x: 0.14, y: 0.02),
            startRadius: 0,
            endRadius: 500
        )
        .ignoresSafeArea()
    }
}

extension View {
    func appBackground() -> some View {
        background(AppBackground())
    }
}
