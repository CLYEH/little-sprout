import CoreGraphics

/// `PrintPhotoCard` 的幾何常數（LS-406，LS-390 R1 I4）：角托邊長與染料池圓的大小。
///
/// 幾何常數獨立一份、由 `PrintPhotoCard` 與 `AlbumSummaryCardView` 共用（後者原本寫死 `cornerSize * 6`，
/// LS-407），改角托尺寸時兩處染料池一起動。LS-406 曾為了讓 UITest 裁圖扣掉染料池半徑而把它同時掛進
/// `LittleSproutUITests`；LS-407 時間軸相簿卡的 a11y frame 改為紙面後，裁圖不再需要，已從 `project.yml` 拿掉。
enum PrintPhotoCardMetrics {
    /// 角托預設邊長（`PrintPhotoCard.cornerSize`）。
    static let cornerSize: CGFloat = 26
    /// 染料池圓直徑＝角托邊長的倍數（圓心在紙的四角）。
    static let mountPoolDiameterFactor: CGFloat = 6

    static func mountPoolDiameter(cornerSize: CGFloat = cornerSize) -> CGFloat {
        cornerSize * mountPoolDiameterFactor
    }
}
