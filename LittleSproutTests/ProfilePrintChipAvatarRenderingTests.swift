import SwiftUI
@testable import LittleSprout
import XCTest

/// LS-345 R2（merge-review R1 m2）：`ProfileAvatarDisplayRegressionTests`／
/// `ProfilePrintChipStructureTests` 守到元件邊界為止——reviewer 用逃逸 mutation 實測，把
/// `ProfilePrintChip.body` 的 `AsyncImage(url: avatarURL)` 改成 `AsyncImage(url: URL?.none)`
/// （沖印框永遠不顯示任何頭像，等同本票要修的 bug 原封不動），全量單元測試仍 1241/1241 綠——
/// 兩支既有測試分別守「`SettingsView` 有沒有把值轉手給 `ProfileSummaryRow`」與「`AsyncImage`
/// 型別字串有沒有被包進條件分支」，都看不到 `url:` 這個參數實際餵了什麼值進去。
///
/// 這裡改用像素渲染比對抓住這最後一哩：把 `ProfilePrintChip` 裝進 `UIHostingController`、
/// 真的渲染到 `UIImage`，比對「有真實頭像」與「沒有頭像（nil）」兩種輸入是不是畫出不同的
/// 像素——同 `QADriver.elementDigest`（`LittleSproutUITests/QA/QADriver.swift`）「渲染後比
/// 圖」的既有思路，差別是這裡在 `XCTest` 層直接渲染、不需要真的跑一輪 XCUITest／模擬器互動。
/// mutation（把 `avatarURL: avatarURL` 改成 `avatarURL: URL?.none`）下，兩態渲染結果會逐位元
/// 相同，這支測試會紅。
@MainActor
final class ProfilePrintChipAvatarRenderingTests: XCTestCase {
    /// 同 `TapTargetGateHarness+DiaryCardVideoBadges.swift` 的 `makeTestImageURL` 既有思路
    /// （那支是 `private`、跨檔案存取不到，這裡另外寫一份最小版，同 `signedAvatarURLs` 那類
    /// 小重複的既有慣例）：runtime 產生一張純色 JPEG、寫進暫存目錄，`AsyncImage` 能用
    /// `file://` URL 直接載入，不依賴網路。
    private func makeTestImageURL(color: UIColor) -> URL {
        let size = CGSize(width: 60, height: 60)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ls345-profile-print-chip-\(UUID().uuidString)", conformingTo: .jpeg)
        try? image.jpegData(compressionQuality: 0.9)?.write(to: url)
        return url
    }

    /// 把 `ProfilePrintChip(avatarURL:)` 裝進真的視窗階層渲染，輪詢等 `AsyncImage` 的非同步
    /// 載入安定下來（`file://` 是本機讀檔、近乎瞬間完成，20 次 × 100ms 遠超實際需要的時間，
    /// 用輪詢而不是固定 `sleep` 是為了不對「多快算穩定」這件事下賭注，同 codebase 既有的
    /// `waitUntilSnapshotChanges` 精神）。回傳渲染出的 PNG bytes，供呼叫端直接比對。
    private func renderedPNG(avatarURL: URL?) async -> Data? {
        let host = UIHostingController(rootView: ProfilePrintChip(avatarURL: avatarURL))
        let frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        host.view.frame = frame
        host.view.backgroundColor = .white
        let window = UIWindow(frame: frame)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        var lastPNG: Data?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: frame)
            let png = renderer.image { ctx in host.view.layer.render(in: ctx.cgContext) }.pngData()
            if png == lastPNG { break }
            lastPNG = png
        }
        window.isHidden = true
        return lastPNG
    }

    /// mutation：把 `ProfilePrintChip.body` 的 `AsyncImage(url: avatarURL)` 改成
    /// `AsyncImage(url: URL?.none)`，這支測試會抓到——兩態渲染出的 PNG 會逐位元相同。
    func test_avatarURL_nilVsRealImage_rendersDifferentPixels() async throws {
        let photoURL = makeTestImageURL(color: .systemBlue)
        defer { try? FileManager.default.removeItem(at: photoURL) }

        let nilResult = await renderedPNG(avatarURL: nil)
        let photoResult = await renderedPNG(avatarURL: photoURL)
        let nilPNG = try XCTUnwrap(nilResult, "avatarURL: nil 的渲染結果不該是空的")
        let photoPNG = try XCTUnwrap(photoResult, "avatarURL: <本地檔案 URL> 的渲染結果不該是空的")

        XCTAssertNotEqual(
            nilPNG, photoPNG,
            "avatarURL 有值時渲染出的像素應該跟 nil（SF Symbol 佔位）不同——如果這裡相等，" +
                "代表 ProfilePrintChip.body 沒有真的把 avatarURL 餵給 AsyncImage（例如被寫死成 nil）"
        )
    }
}
