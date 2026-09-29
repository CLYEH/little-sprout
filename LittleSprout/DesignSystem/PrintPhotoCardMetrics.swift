import CoreGraphics

/// `PrintPhotoCard` 的幾何常數（LS-406，LS-390 R1 I4）：角托邊長與染料池圓的大小。
///
/// 獨立成只依賴 CoreGraphics 的檔案，是因為 XCUITest 跑在分離的行程、不能 `import LittleSprout`
/// 引用 app 型別（見 `project.yml` `LittleSproutUITests` sources 的說明），這個檔案同時掛進 app 與
/// UITest 兩個 target——`AlbumCardImprintCaptionUITests` 裁圖時扣掉的「染料池圓外擴半徑」原本寫死 78，
/// 與 `PrintPhotoCard` 的 26×6÷2 各自維護，改角托尺寸時裁切框會悄悄偏掉。
enum PrintPhotoCardMetrics {
    /// 角托預設邊長（`PrintPhotoCard.cornerSize`）。
    static let cornerSize: CGFloat = 26
    /// 染料池圓直徑＝角托邊長的倍數（圓心在紙的四角）。
    static let mountPoolDiameterFactor: CGFloat = 6

    static func mountPoolDiameter(cornerSize: CGFloat = cornerSize) -> CGFloat {
        cornerSize * mountPoolDiameterFactor
    }

    /// 染料池圓半徑；a11y frame 會把四角的圓一起算進去，四邊各外擴這個距離。
    static func mountPoolRadius(cornerSize: CGFloat = cornerSize) -> CGFloat {
        mountPoolDiameter(cornerSize: cornerSize) / 2
    }
}
