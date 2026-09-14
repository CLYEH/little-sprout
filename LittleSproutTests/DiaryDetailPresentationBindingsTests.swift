import Foundation
@testable import LittleSprout
import XCTest

/// LS-266（池 `7858d2fc` i1，來源 LS-246 merge-review R1 `fc5bc56f`）：
/// `DiaryDetailView.sheetBinding` 的 setter 收到 `nil` 時「目前是 `.video` 就不清」的守衛
/// 原本無測試釘住（reviewer 自加 mutation 存活；iOS 26.0 程式化 dismiss 不回寫 `set(nil)`，
/// UITest 走不到）。改成呼叫抽出的 `static` 純函式
/// `DiaryDetailView.activeSheetAfterSheetBindingCleared(currentActiveSheet:)`，直接單元測試。
final class DiaryDetailPresentationBindingsTests: XCTestCase {
    /// 核心釘樁：目前正在播放影片（`.video`）時，`sheetBinding` 的 dismiss 手勢寫回 `nil`
    /// 不該把它清掉——那是影片正在播放，不是這個 binding 該清的狀態。mutation（拿掉這個守衛、
    /// 一律清成 `nil`）會讓這支測試轉紅。
    func test_activeSheetAfterSheetBindingCleared_whenVideoPlaying_keepsVideo() {
        let video = PlayingVideo(url: URL(string: "https://example.com/clip.mp4")!)

        let result = DiaryDetailView.activeSheetAfterSheetBindingCleared(currentActiveSheet: .video(video))

        XCTAssertEqual(result?.id, DiaryDetailSheet.video(video).id, "影片正在播放時不該被 sheet 的收起動作誤清掉")
    }

    /// 對照組：`.comments`／`.contentActions`／`nil` 三種情況都該真的清空。
    func test_activeSheetAfterSheetBindingCleared_whenNotVideo_clearsToNil() {
        XCTAssertNil(DiaryDetailView.activeSheetAfterSheetBindingCleared(currentActiveSheet: .comments))
        XCTAssertNil(DiaryDetailView.activeSheetAfterSheetBindingCleared(currentActiveSheet: nil))
    }
}
