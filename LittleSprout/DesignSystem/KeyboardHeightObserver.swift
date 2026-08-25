import Combine
import SwiftUI

/// LS-105：追蹤系統鍵盤實際高度。
///
/// `safeAreaInset(edge: .bottom)` 的 CTA 會正確貼著鍵盤上緣移動（safe area 本來就含鍵盤），
/// 但 `ScrollView` 本身的可捲動內容不會因為鍵盤出現而跟著收縮可視範圍——實測：鍵盤彈出時
/// 內容幾乎原地不動，CTA 貼上來後兩者在鍵盤與 CTA 之間的空隙重疊（PR 說明有截圖）。用這個
/// observer 拿到即時鍵盤高度，讓呼叫端把它當 `contentMargins(.bottom)` 加給 ScrollView，
/// 可捲動內容的可視底界才會跟著鍵盤一起收縮，兩者不再互相蓋到。
@MainActor
@Observable
final class KeyboardHeightObserver {
    private(set) var height: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        let willChange = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .compactMap { note -> CGFloat? in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                    return nil
                }
                // 鍵盤 frame 在螢幕座標系已是「貼齊底部」的高度，不需再對 UIScreen 做算術
                // （UIScreen.main 在 MainActor 隔離下不可從非隔離 context 取用；frame.height
                // 本身就等價於原本 screenHeight - frame.origin.y 的結果）。
                return frame.height
            }
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }

        willChange.merge(with: willHide)
            .sink { [weak self] in self?.height = $0 }
            .store(in: &cancellables)
    }
}
