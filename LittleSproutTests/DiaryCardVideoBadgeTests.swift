import AVFoundation
import Foundation
@testable import LittleSprout
import os
import XCTest

/// fix/LS-130-video-badge-fallback（QA R2 FAIL，comment `a999c9af`）：無縮圖的舊影片在
/// 時間軸日記卡的附照預覽完全沒有任何徽章——`DiaryCardView` 修前對 `.video` 沒有任何特殊
/// 處理，`AsyncImage` 對 `.mov` 解不出圖片，退回空白 `Color.lsSurface2` 矩形；詳情頁的
/// `MasonryPhotoWallView` 卻能正確讀出時長（accessibility label「影片 0:08，點兩下播放」）
/// ——缺陷只在時間軸日記卡這個呈現層。
///
/// 這裡串接 `DiaryCardView`／`PhotoCardView` 徽章邏輯實際依賴的三個生產函式
/// （`MediaContent.needsVideoDurationLookup`／`TimelineStore.loadVideoDuration`／
/// `VideoDurationFormat.badgeText`），照 View 呼叫的**順序**驗證三段狀態機：
///   1. 無縮圖舊影片：初始「影片」→ `loadVideoDuration` 成功後「影片 M:SS」。
///   2. 縮圖影片：`needsVideoDurationLookup` 為 false，`loadVideoDuration` 連呼叫都不該
///      發生，恆「影片」。
///   3. 無縮圖舊影片讀取失敗：恆「影片」，不掛假時長。
///
/// 誠實界定：這條鏈本身（三個生產函式）在別的測試檔已個別鎖住；這裡新增的價值是**串成
/// `DiaryCardView` 實際使用的順序**，把「有沒有正確接線」的意圖寫進測試名稱與斷言（Rule 8：
/// 測試要編碼「為什麼」，不只是「是什麼」）。View 的 `.task` guard／`VideoDurationBadge`
/// 是否真的呼叫了這條鏈，本 repo 沒有 View 單元測試路徑可驗（同 `PhotoCardView`／
/// `MasonryPhotoWallView` 的既有測試缺口，多輪 merge-review 已確認、接受這個限制）——
/// 那一段改用模擬器實拍佐證，見 PR body。
final class DiaryCardVideoBadgeTests: XCTestCase {
    @MainActor
    func test_legacyVideo_initialBadgeIsPlainLabel_thenUpgradesToMinutesSecondsAfterLoad() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let store = TimelineStore(
            apiClient: stub, durationLoader: { _ in CMTime(seconds: 8, preferredTimescale: 600) }
        )
        let photo = legacyVideo(id: mediaID)

        // 初始狀態（DiaryCardView 的 .task 尚未跑完）：videoDurations 沒有這個 id。
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: store.videoDurations[photo.id]), "影片")

        // DiaryCardView 的 .task guard：無縮圖舊影片該觸發讀取。
        XCTAssertTrue(photo.needsVideoDurationLookup, "無縮圖舊影片仍要查時長，不能因為本票而迴歸")
        await store.loadVideoDuration(mediaID: photo.id, url: photo.signedURL!)

        XCTAssertEqual(
            VideoDurationFormat.badgeText(duration: store.videoDurations[photo.id]), "影片 0:08",
            "讀到時長後徽章該換成「影片 M:SS」"
        )
    }

    @MainActor
    func test_thumbnailVideo_neverAttemptsLoad_badgeStaysPlainLabel() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let attemptCount = OSAllocatedUnfairLock(initialState: 0)
        let store = TimelineStore(apiClient: stub, durationLoader: { _ in
            attemptCount.withLock { $0 += 1 }
            return CMTime(seconds: 8, preferredTimescale: 600)
        })
        let photo = thumbnailVideo(id: mediaID)

        // DiaryCardView 的 .task guard 就是 `photo.needsVideoDurationLookup`——縮圖列為
        // false，這裡直接照那個 guard 的語意走，不呼叫 loadVideoDuration。
        XCTAssertFalse(photo.needsVideoDurationLookup, "縮圖列不該查時長——signedURL 是 JPEG，讀了必失敗")
        if photo.needsVideoDurationLookup {
            await store.loadVideoDuration(mediaID: photo.id, url: photo.signedURL!)
        }

        XCTAssertEqual(attemptCount.withLock { $0 }, 0, "縮圖列連第一次嘗試都不該發生")
        XCTAssertEqual(VideoDurationFormat.badgeText(duration: store.videoDurations[photo.id]), "影片")
    }

    @MainActor
    func test_legacyVideo_loadFailure_badgeStaysPlainLabel_noFakeDuration() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let store = TimelineStore(apiClient: stub, durationLoader: { _ in
            throw AppError.server(message: "無法解析真實影片檔的時長", code: nil)
        })
        let photo = legacyVideo(id: mediaID)

        await store.loadVideoDuration(mediaID: photo.id, url: photo.signedURL!)

        XCTAssertEqual(
            VideoDurationFormat.badgeText(duration: store.videoDurations[photo.id]), "影片",
            "讀取失敗不掛假時長，退回純文字「影片」"
        )
    }

    /// LS-135：有縮圖＋`media.duration_seconds` 有值（LS-135 之後上傳的新影片，量測成功）
    /// ——徽章該直接顯示查表值，`loadVideoDuration` 連呼叫都不該發生（縮圖 JPEG 解不出
    /// 時長，且已經有權威值不需要再查）。跟 `test_thumbnailVideo_neverAttemptsLoad_
    /// badgeStaysPlainLabel` 是同一個「不查」斷言，差別在這裡驗證徽章不是恆「影片」，而是
    /// 直接顯示 `durationSeconds`——修前（只讀 `videoDurations` 快取）這個案例會錯誤顯示
    /// 純文字「影片」，是 LS-135 要修的缺陷本身。
    @MainActor
    func test_thumbnailVideoWithDurationSeconds_neverAttemptsLoad_badgeShowsDbDurationImmediately() async {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        let attemptCount = OSAllocatedUnfairLock(initialState: 0)
        let store = TimelineStore(apiClient: stub, durationLoader: { _ in
            attemptCount.withLock { $0 += 1 }
            return CMTime(seconds: 999, preferredTimescale: 600)
        })
        let photo = thumbnailVideo(id: mediaID, durationSeconds: 45)

        XCTAssertFalse(
            photo.needsVideoDurationLookup, "duration_seconds 已有查表值，不該再讀縮圖 JPEG 猜時長"
        )
        if photo.needsVideoDurationLookup {
            await store.loadVideoDuration(mediaID: photo.id, url: photo.signedURL!)
        }

        XCTAssertEqual(attemptCount.withLock { $0 }, 0, "有 duration_seconds 時連第一次嘗試都不該發生")
        XCTAssertEqual(
            VideoDurationFormat.badgeText(duration: store.displayDuration(for: photo)), "影片 0:45",
            "徽章該直接顯示 media.duration_seconds 查表值，不是退化成純文字「影片」——這正是 LS-135 要修的缺陷"
        )
    }

    private func legacyVideo(id: UUID) -> MediaContent {
        MediaContent(
            id: id, type: .video, width: 884, height: 1920, thumbWidth: nil, thumbHeight: nil,
            storagePath: "f/\(id).mov", isThumbnail: false,
            signedURL: URL(string: "https://example.com/f/\(id).mov"), durationSeconds: nil
        )
    }

    private func thumbnailVideo(id: UUID, durationSeconds: Int? = nil) -> MediaContent {
        MediaContent(
            id: id, type: .video, width: 884, height: 1920, thumbWidth: 235, thumbHeight: 512,
            storagePath: "f/\(id).mov", isThumbnail: true,
            signedURL: URL(string: "https://example.com/f/\(id)_thumb.jpg"), durationSeconds: durationSeconds
        )
    }
}
