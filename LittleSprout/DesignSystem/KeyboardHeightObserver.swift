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
            .compactMap { note -> (height: CGFloat, duration: TimeInterval)? in
                guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                    return nil
                }
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                return (Self.height(endFrame: endFrame, screenBounds: Self.foregroundScreenBounds()), duration)
            }
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { note -> (height: CGFloat, duration: TimeInterval) in
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                return (0, duration)
            }

        // PR #165 review F4：高度變化跟著系統鍵盤動畫的 duration 一起做，CTA／
        // contentMargins 才不會跟丟——長輩對「內容忽然跳一格」的容忍度低。
        willChange.merge(with: willHide)
            .sink { [weak self] value in
                withAnimation(.easeOut(duration: value.duration)) {
                    self?.height = value.height
                }
            }
            .store(in: &cancellables)
    }

    // PR #165 review F3：`UIScreen.main` 是單一裝置螢幕，多 scene（`Info.plist`
    // `UIApplicationSupportsMultipleScenes = true`）下不保證是「這個 observer 所在的
    // scene」；改成取目前 foreground-active 的 `UIWindowScene`。
    private static func foregroundScreenBounds() -> CGRect {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
        return scene?.screen.bounds ?? .zero
    }

    // PR #165 review I2：抽成不碰 UIKit 的純函式，可直接單元測試（KeyboardHeightObserverTests）。
    // 只有鍵盤下緣真的貼齊螢幕底（一般鍵盤、分離／懸浮鍵盤靠邊停靠時）才視為遮住底部 UI；
    // 懸浮鍵盤浮在畫面中間、下緣不貼底時回傳 0——不佔用 contentMargins／CTA 空間（review F3）。
    nonisolated static func height(endFrame: CGRect, screenBounds: CGRect) -> CGFloat {
        guard endFrame.maxY >= screenBounds.maxY - 1 else {
            return 0
        }
        return max(0, screenBounds.maxY - endFrame.minY)
    }
}
