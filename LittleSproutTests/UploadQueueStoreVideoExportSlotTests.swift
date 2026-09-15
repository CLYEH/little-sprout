import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-288：`UploadQueueStore` 影片 export 專屬並行名額（`acquireVideoExportSlot()`／
/// `releaseVideoExportSlot()`，LS-286 i2 引入）的等待佇列本身行為——取消（i1）與逾時看門狗
/// （i3）各自的邊界情境。拆成獨立檔案（沿 `UploadQueueStoreVideoCompressionTests.swift` 檔頭
/// 慣例）：避免單一測試檔撞 SwiftLint `type_body_length`，也讓「export 名額佇列」與「壓縮輸出
/// 是否正確接上」這兩個關注點分開。`makeUpload`／`waitUntil` 各自維護一份，理由同兩者既有註解。
@MainActor
final class UploadQueueStoreVideoExportSlotTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeVideoUpload(fileURL: URL, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .video(fileURL: fileURL, fileExtension: "mp4"), thumbnail: nil,
            pixelSize: PixelSize(width: 3840, height: 2160)
        )
    }

    private func makeTempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data("stub".utf8))
        return url
    }

    /// `UploadQueueStoreVideoCompressionTests` 既有的輪詢慣例：限時等到某個條件成立，逾時直接
    /// `XCTFail`（不是靜默通過），避免卡死整個測試行程。
    private func waitUntil(
        timeoutSeconds: Double = 1, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                return XCTFail("等待條件成立逾時", file: file, line: line)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 等待名額的 Task 被取消（mutation：拿掉 withTaskCancellationHandler／不從佇列移除）

    /// i1（LS-286 R1 informational `dc010dd7`）：`acquireVideoExportSlot()` 排隊等待名額時，若
    /// 呼叫端的 Task 被取消，等待者要立刻被移出佇列並收到 `CancellationError`——不能繼續佔用
    /// 隊列位置，卡住排在它後面、原本可以合法拿到名額的其他等待者。用
    /// `debugAcquireVideoExportSlot()`／`debugReleaseVideoExportSlot()` 直接驅動 acquire／
    /// release，不經過完整的 `enqueue`／`performUpload`（`UploadQueueStore` 目前沒有任何呼叫端
    /// 會取消飛行中的 Task，見檔頭文件「已知限制」——這裡是在單元測試層級直接施加取消，驗證
    /// 等待佇列本身的行為，不代表今天有真實情境會觸發）。
    func test_acquireVideoExportSlot_waiterCancelled_removedFromQueue_doesNotBlockNextWaiter() async throws {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: StubMediaUploadService())

        // 名額 1：立刻拿到（沒人在跑）。
        try await store.debugAcquireVideoExportSlot()

        let waiter2Result = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
        let waiter2 = Task {
            do {
                try await store.debugAcquireVideoExportSlot()
                waiter2Result.withLock { $0 = .success(()) }
            } catch {
                waiter2Result.withLock { $0 = .failure(error) }
            }
        }
        await waitUntil { store.debugVideoExportWaiterCount == 1 }

        let waiter3GotSlot = OSAllocatedUnfairLock(initialState: false)
        let waiter3 = Task {
            try await store.debugAcquireVideoExportSlot()
            waiter3GotSlot.withLock { $0 = true }
        }
        await waitUntil { store.debugVideoExportWaiterCount == 2 }

        waiter2.cancel()
        // 取消要讓等待者立刻被移出佇列——不是等到名額釋放才發現。
        await waitUntil { store.debugVideoExportWaiterCount == 1 }
        _ = await waiter2.result
        let isCancellationError = waiter2Result.withLock { result -> Bool in
            if case .failure(is CancellationError) = result { return true }
            return false
        }
        XCTAssertTrue(
            isCancellationError, "取消的等待者應該收到 CancellationError，實際 \(String(describing: waiter2Result.withLock { $0 }))"
        )

        // 名額 1 釋放——排在佇列裡唯一剩下的（waiter3）應該立刻拿到，不被已取消的 waiter2 卡住。
        store.debugReleaseVideoExportSlot()
        await waitUntil(timeoutSeconds: 0.5) { waiter3GotSlot.withLock { $0 } }
        _ = try await waiter3.value
        XCTAssertTrue(waiter3GotSlot.withLock { $0 }, "第 3 個等待者應該在第 1 個釋放後立即取得名額，不被已取消的第 2 個卡住")
        XCTAssertEqual(store.debugVideoExportWaiterCount, 0, "佇列應該清空")
    }

    // MARK: - export 逾時看門狗（mutation：拿掉看門狗）

    /// i3（LS-286 R1 informational `dc010dd7`）：`videoPreparer` 卡住不回應時（`AVAssetExportSession`
    /// 停住），沒有看門狗的話這一筆會永遠佔著 export 名額，連帶卡住佇列裡其他所有影片。注入
    /// 50ms 逾時＋永不返回、不理會取消信號的 preparer（用 `withCheckedContinuation` 永遠不
    /// resume，模擬真的卡住的 `AVAssetExportSession`——`Task.sleep` 本身會回應取消，測不出「不
    /// 理會取消信號」這個最壞情況）——逾時後這一筆要標成專屬失敗原因、不可重試，下一支影片要能
    /// 立刻取得名額並被呼叫。
    func test_video_exportWatchdog_timesOut_failsRetryableFalseAndReleasesSlotForNextVideo() async {
        let stuckURL = makeTempFile()
        let okURL = makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: stuckURL)
            try? FileManager.default.removeItem(at: okURL)
        }
        let mediaService = StubMediaUploadService()
        mediaService.setUploadVideoHandler { _, _, _, _ in UUID() }
        let okPreparerCalls = OSAllocatedUnfairLock(initialState: 0)
        let store = UploadQueueStore(
            familyID: familyID, mediaUploadService: mediaService, videoExportTimeout: .milliseconds(50),
            videoPreparer: { fileURL in
                if fileURL == stuckURL {
                    return await withCheckedContinuation { (_: CheckedContinuation<VideoTrimmer.UploadSource, Never>) in
                        // 故意永遠不 resume——模擬卡住、不理會取消信號的 AVAssetExportSession。
                    }
                }
                okPreparerCalls.withLock { $0 += 1 }
                return VideoTrimmer.UploadSource(fileURL: okURL, fileExtension: "mp4", pixelSize: nil)
            }
        )

        store.enqueue([makeVideoUpload(fileURL: stuckURL), makeVideoUpload(fileURL: okURL)])

        // 不能等 `remainingCount == 0`——失敗列本身也算「還沒完成」（見 `remainingCount` 文件
        // 註解），卡住那支逾時後仍是失敗列，`remainingCount` 永遠不會歸零；改等兩筆都離開
        // `.waiting`／`.uploading`（各自到達失敗或完成的終局狀態）。
        await waitUntil(timeoutSeconds: 3) { store.waitingCount == 0 && store.uploadingCount == 0 }

        XCTAssertEqual(okPreparerCalls.withLock { $0 }, 1, "第一支卡住逾時後，第二支應該取得名額並被呼叫")
        XCTAssertEqual(mediaService.uploadVideoCalls.count, 1, "只有第二支影片真正上傳")
        guard let failedRow = store.sections.first(where: { $0.kind == .failed })?.rows.first else {
            return XCTFail("卡住逾時的那支應該落在失敗態")
        }
        guard case .failed(let reason) = failedRow.state else { return XCTFail("預期失敗態") }
        XCTAssertEqual(reason, .videoExportTimedOut, "逾時要標成專屬的失敗原因，不是通用的伺服器忙碌")
        XCTAssertFalse(reason.isRetryable, "同一支卡住的原始檔案重試大機率再次卡住同一個地方，不該提供重試")
    }
}
