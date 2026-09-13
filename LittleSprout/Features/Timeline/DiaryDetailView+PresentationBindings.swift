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
            set: { newValue in
                if let newValue {
                    activeSheet = newValue
                } else if case .video = activeSheet {
                    // 影片正在播放（見上方文件註解），不是這個 binding 該清的狀態。
                } else {
                    activeSheet = nil
                }
            }
        )
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
