import AVKit
import SwiftUI

/// 影片全螢幕系統播放器（`AVPlayerViewController`）——日記詳情瀑布流照片牆點一下影片格觸發
/// （LS-126 票文 Scope 2）。主時間軸的照片卡「不自動播放、不內嵌播放器」（票文明文要求），
/// 只有這裡（日記詳情）才真的有播放器，且是系統原生全螢幕介面，不是自畫的內嵌播放器。
struct VideoPlayerScreen: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

/// `.fullScreenCover(item:)` 需要 `Identifiable`——只帶 URL 本身當 id，不需要額外欄位。
struct PlayingVideo: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}
