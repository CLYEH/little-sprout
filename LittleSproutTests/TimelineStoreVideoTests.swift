import AVFoundation
import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-130 `signFullSizeURL`／R2-M1（merge-review `b7ecfbf4`）`loadVideoDuration` 失敗不重試。
/// 跟 `TimelineStoreTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`／`file_length`（同 `OTPVerificationModelRateLimitTests.swift` 的拆檔
/// 理由與寫法）。
@MainActor
extension TimelineStoreTests {
    // MARK: - LS-130：signFullSizeURL——全尺寸原檔只在放大檢視／播放影片當下現簽

    func test_signFullSizeURL_signsGivenStoragePathAndReturnsSignedURL() async throws {
        let stub = StubTimelineAPIClient()
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }
        let store = TimelineStore(apiClient: stub)

        let url = try await store.signFullSizeURL(storagePath: "f/original.mp4")

        XCTAssertEqual(url, URL(string: "https://example.com/f/original.mp4"))
        XCTAssertEqual(
            stub.signedURLsCalls, [["f/original.mp4"]],
            "只該現簽這一個路徑一次——不是在列表載入時就順便簽好"
        )
    }

    func test_signFullSizeURL_signingFails_returnsNil() async throws {
        let stub = StubTimelineAPIClient()
        stub.setSignedURLsHandler { _ in [:] } // 單一路徑簽名失敗時該路徑不會出現在字典裡（見協定文件）。
        let store = TimelineStore(apiClient: stub)

        let url = try await store.signFullSizeURL(storagePath: "f/deleted.mp4")

        XCTAssertNil(url, "簽名失敗時回傳 nil，呼叫端不播放")
    }

    // MARK: - R2-M1（merge-review `b7ecfbf4`）：loadVideoDuration 失敗不重試

    func test_loadVideoDuration_success_recordsDuration() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let store = TimelineStore(
            apiClient: stub, durationLoader: { _ in CMTime(seconds: 12.5, preferredTimescale: 600) }
        )

        await store.loadVideoDuration(mediaID: mediaID, url: URL(string: "https://example.com/v.mov")!)

        XCTAssertEqual(store.videoDurations[mediaID] ?? -1, 12.5, accuracy: 0.01)
    }

    /// 核心迴歸測試：R1 major——`loadVideoDuration` 原本失敗後什麼都不記，同一支影片的卡片
    /// 隨 `LazyVStack` 重建（捲出、捲回存活視窗）就會對必定失敗的 URL 重打一次
    /// `AVURLAsset` 請求，次數隨捲動線性成長。`durationLoader` 用計數 closure 斷言「同一個
    /// mediaID 呼叫 `loadVideoDuration` 兩次，底層讀取動作只真正被呼叫一次」——不必真的打
    /// 網路、也不用等 AVFoundation 對一個必失敗的 URL 逾時。
    func test_loadVideoDuration_secondCallAfterFailure_doesNotRetryDurationLoader() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let attemptCount = OSAllocatedUnfairLock(initialState: 0)
        let store = TimelineStore(apiClient: stub, durationLoader: { _ in
            attemptCount.withLock { $0 += 1 }
            throw AppError.server(message: "無法解析縮圖 JPEG 的時長", code: nil)
        })
        let url = URL(string: "https://example.com/thumb.jpg")!

        await store.loadVideoDuration(mediaID: mediaID, url: url)
        await store.loadVideoDuration(mediaID: mediaID, url: url)

        XCTAssertNil(store.videoDurations[mediaID], "失敗的話不該有任何時長被記下")
        XCTAssertEqual(
            attemptCount.withLock { $0 }, 1,
            "第二次呼叫該被 failedDurations 擋下——不是又真的嘗試載入一次"
        )
    }
}
