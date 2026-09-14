import SwiftUI

/// LS-246（票文範圍 1）：`sheetBinding`／`videoBinding` 從 `DiaryDetailView.swift` 拆出獨立
/// 檔案——同 `DiaryDetailView+ContentActions.swift` 既有先例（該檔文件註解），本體疊上這兩支
/// derived binding 之後會超過 SwiftLint `file_length` 上限。兩者都不是 `private`：跨檔案
/// extension 存取不到（同 `DiaryDetailView.activeSheet` 等既有理由）。
extension DiaryDetailView {
    /// LS-246：`.sheet(item:)` 只認 `activeSheet` 是 `.comments`／`.contentActions` 的時刻——
    /// `.video` 時回傳 nil，讓 SwiftUI 把目前顯示中的 sheet（若有）收起來，改由
    /// `videoBinding`／`.fullScreenCover(item:)` 接手呈現。setter 對稱處理：外部（sheet 自己
    /// 的 dismiss 手勢）把值寫回 nil 時，若目前其實是 `.video`（不是這個 binding 呈現出來的
    /// 那個 sheet），不能真的清空——那是影片正在播放，不該被 sheet 的收起動作誤清掉。
    var sheetBinding: Binding<DiaryDetailSheet?> {
        Binding(
            get: {
                switch activeSheet {
                case .comments, .contentActions: activeSheet
                case .video, .none: nil
                }
            },
            // LS-266 R2 m1（merge-review R1 `443e910f`）：`.video` 時原碼是完全不碰 @State 的
            // 空分支——R1 版把它改成 `activeSheet = activeSheetAfterSheetBindingCleared(...)`，
            // `.video` 時等於 `activeSheet = activeSheet` 自我賦值，不是真的零改變
            // （`DiaryDetailSheet` 只 conform `Identifiable`，SwiftUI 不會對非 Equatable 的
            // @State 做相等去重，這行會多觸發一次 invalidation）。改成只在「真的需要清空」
            // （純函式回傳 nil）才寫，`.video` 時整段跳過、完全不碰 @State，語意與抽函式前
            // 逐位相同；純函式本體與既有測試都不用動。
            set: { newValue in
                if let newValue {
                    activeSheet = newValue
                } else if Self.activeSheetAfterSheetBindingCleared(currentActiveSheet: activeSheet) == nil {
                    activeSheet = nil
                }
            }
        )
    }

    /// LS-266（池 `7858d2fc` i1，來源 LS-246 merge-review R1 `fc5bc56f`）：`sheetBinding` setter
    /// 收到 `nil`（sheet 自己的 dismiss 手勢）時該不該真的清空 `activeSheet` 的判斷，抽成
    /// `static` 純函式方便直接單元測試（不需要建構完整 `DiaryDetailView` 去戳 `Binding`）——
    /// 目前是 `.video`（影片正在播放，不是這個 binding 該清的狀態，見 `sheetBinding` 文件註解）
    /// 就原封不動傳回去，其餘情況才真的清空。
    static func activeSheetAfterSheetBindingCleared(currentActiveSheet: DiaryDetailSheet?) -> DiaryDetailSheet? {
        if case .video = currentActiveSheet {
            return currentActiveSheet
        }
        return nil
    }

    /// LS-246：`.fullScreenCover(item:)` 只認 `activeSheet == .video(...)` 的時刻，鏡射
    /// `sheetBinding` 的邏輯——見該屬性文件註解。
    var videoBinding: Binding<PlayingVideo?> {
        Binding(
            get: {
                if case .video(let video) = activeSheet { return video }
                return nil
            },
            set: { newValue in
                if let newValue {
                    activeSheet = .video(newValue)
                } else if case .video = activeSheet {
                    activeSheet = nil
                }
            }
        )
    }
}
