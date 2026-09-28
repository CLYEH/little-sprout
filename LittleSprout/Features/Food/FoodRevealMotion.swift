import SwiftUI

/// 06「收下這一刻」動效規格（`design/littlesprout.pen` `jIWO6`；Notes `cEkCH`，R3 MJ-8）——抽成純值讓
/// `FoodRevealMotionTests` 鎖住兩個分支，不必在測試裡播動畫。
///
/// - 一般：`withAnimation(.easeOut(duration: 0.35))`（不用 spring，停穩時間＝標示時間）；貼紙去灰、底
///   透明→`$print-paper`、框 `$border`→`$paper-edge`、落影出現，同時 y −2→0（紙片落回台紙）；不縮放。
/// - 減少動態效果（`accessibilityReduceMotion`）：0.2s 淡入淡出、不位移。
enum FoodRevealMotion {
    enum Curve: Equatable {
        case easeOut
        case easeInOut
    }

    struct Spec: Equatable {
        let curve: Curve
        let duration: Double
        /// 播放前那一格的 y 位移（播放時動畫回 0）。
        let startOffsetY: CGFloat
    }

    static func spec(reduceMotion: Bool) -> Spec {
        reduceMotion
            ? Spec(curve: .easeInOut, duration: 0.2, startOffsetY: 0)
            : Spec(curve: .easeOut, duration: 0.35, startOffsetY: -2)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        let spec = spec(reduceMotion: reduceMotion)
        switch spec.curve {
        case .easeOut: return .easeOut(duration: spec.duration)
        case .easeInOut: return .easeInOut(duration: spec.duration)
        }
    }
}
