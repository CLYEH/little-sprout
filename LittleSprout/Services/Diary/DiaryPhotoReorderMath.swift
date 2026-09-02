import CoreGraphics

/// 長按拖曳排序的落點換算——純函式，跟 `DragGesture`／SwiftUI 完全脫鉤，方便單元測試直接釘住
/// 邊界（放開位置換算出界時要夾住，不能讓陣列 index 越界）。`design/littlesprout.pen` Handoff
/// Notes `v0tLp`：「長按…放開後依放開位置重新排序」——落點只在手指放開的那一刻才計算一次
/// （不是拖曳過程即時重排整個陣列），對應 `DiaryComposerStore.move(id:toIndex:)` 的呼叫時機。
enum DiaryPhotoReorderMath {
    /// 縮圖寬度 96pt＋群內間距 8pt（`$sp-label`）＝一格橫移的距離。
    static let cellStride: CGFloat = 96 + 8

    /// `translationWidth`：放開當下 `DragGesture.translation.width`（正＝往右拖）。
    static func targetIndex(sourceIndex: Int, translationWidth: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let delta = Int((translationWidth / cellStride).rounded())
        return min(max(0, sourceIndex + delta), count - 1)
    }
}
