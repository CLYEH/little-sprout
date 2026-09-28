import SwiftUI
import XCTest
@testable import LittleSprout

/// LS-380 票文範圍 4／驗收「動效 reduce-motion 分支」：06「收下」動效的兩個分支（Notes `cEkCH`）——一般
/// `.easeOut(0.35)`＋y −2→0；減少動態效果 0.2s 淡入淡出不位移。`FoodBookView` 放開那一格時只讀這支規格。
final class FoodRevealMotionTests: XCTestCase {
    func test_revealMotion_default_isEaseOut035WithTwoPointDrop() {
        XCTAssertEqual(
            FoodRevealMotion.spec(reduceMotion: false),
            FoodRevealMotion.Spec(curve: .easeOut, duration: 0.35, startOffsetY: -2)
        )
        XCTAssertEqual(FoodRevealMotion.animation(reduceMotion: false), Animation.easeOut(duration: 0.35))
    }

    func test_revealMotion_reduceMotion_isShortFadeWithoutMovement() {
        XCTAssertEqual(
            FoodRevealMotion.spec(reduceMotion: true),
            FoodRevealMotion.Spec(curve: .easeInOut, duration: 0.2, startOffsetY: 0),
            "減少動態效果：0.2s 淡入淡出、不位移"
        )
        XCTAssertEqual(FoodRevealMotion.animation(reduceMotion: true), Animation.easeInOut(duration: 0.2))
    }
}
