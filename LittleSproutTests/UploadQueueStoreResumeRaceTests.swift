import Foundation
@testable import LittleSprout
import os
import XCTest

/// LS-397 merge-review R1 M1／M3 的回歸測試（反例由 merge-reviewer 提出，見 PR #573 R1 comment
/// `2ea6d552`）：背景寬限期內才開始的上傳不能漏掉重送、重送不能在伺服器多出一列 `media`。
@MainActor
final class UploadQueueStoreResumeRaceTests: XCTestCase {
    private func makeUpload(_ tag: String, id: UUID = UUID()) -> PendingUpload {
        PendingUpload(
            id: id, kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    private func waitUntil(timeoutSeconds: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func completedCount(_ store: UploadQueueStore) -> Int {
        store.rows.filter { $0.state == .completed }.count
    }

    /// R1 M1：`.background` 送到之後、app 被暫停之前還有幾秒寬限期。這段時間有一張在飛的上傳完成、
    /// `advance()` 接著開始下一張——那張不在進背景當下的快照裡；暫停把它的 socket 收掉，回前景後
    /// 它以 `URLError` 失敗，必須被自動重送，不能留成「重試這 1 張」。
    func test_itemStartedDuringBackgroundGrace_isResumedAfterForeground() async {
        enum Phase { case foreground, background, active }
        let phase = OSAllocatedUnfairLock(initialState: Phase.foreground)
        let attempts = OSAllocatedUnfairLock(initialState: [Int: Int]())
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoHandler { _, data, _, _ in
            let tag = Int(String(bytes: data, encoding: .utf8) ?? "") ?? 0
            let attempt = attempts.withLock { counts -> Int in
                counts[tag, default: 0] += 1
                return counts[tag] ?? 0
            }
            if attempt == 1, tag == 15 || tag == 16 {
                try await Task.sleep(for: .seconds(60)) // 被暫停：不回應，直到被取消
            }
            if attempt == 1, tag == 17 { // 進背景後才完成（寬限期內）
                while phase.withLock({ $0 }) == .foreground { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            if attempt == 1, tag == 18 { // 背景中才開始；暫停收掉 socket，回前景後才失敗
                while phase.withLock({ $0 }) != .active { try await Task.sleep(nanoseconds: 2_000_000) }
                throw URLError(.networkConnectionLost)
            }
            return UUID()
        }
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: mediaService, maxConcurrentUploads: 3)
        addTeardownBlock { @MainActor in store.discardPersistedState() }

        store.enqueue((0..<30).map { makeUpload("\($0)") })
        await waitUntil { self.completedCount(store) == 15 && store.uploadingCount == 3 }
        store.appDidEnterBackground()
        phase.withLock { $0 = .background }
        await waitUntil { self.completedCount(store) == 16 && store.uploadingCount == 3 }
        store.appDidBecomeActive()
        phase.withLock { $0 = .active }
        await waitUntil { store.remainingCount == 0 || store.failedCount > 0 }
        await waitUntil(timeoutSeconds: 1) { store.remainingCount == 0 }

        XCTAssertEqual(store.failedCount, 0, "背景寬限期內才開始的上傳被暫停中斷後，必須自動重送，不能留成失敗項")
        XCTAssertEqual(store.remainingCount, 0, "回前景後 30 張要全部完成")
    }

    /// R1 M3：INSERT 已在伺服器 commit、回應卻沒回到 app（被暫停）→ 回前景取消並重送。重送必須沿用
    /// 同一個 `media.id`（佇列項 id），伺服器（這裡用「同 id 只算一列」模擬主鍵）才不會多出重複列；
    /// 所有嘗試都要帶非 `nil` 的 `mediaID`，且同一筆的每次嘗試 id 相同。
    func test_resendAfterLostResponse_reusesMediaID_soServerHasNoDuplicateRow() async {
        let serverRows = OSAllocatedUnfairLock(initialState: Set<UUID>())
        let attempts = OSAllocatedUnfairLock(initialState: [String: Int]())
        let mediaService = StubMediaUploadService()
        mediaService.setUploadPhotoMediaIDHandler { mediaID, data in
            let tag = String(bytes: data, encoding: .utf8) ?? ""
            let attempt = attempts.withLock { counts -> Int in
                counts[tag, default: 0] += 1
                return counts[tag] ?? 0
            }
            let id = mediaID ?? UUID() // 沒指定 id＝服務自己產生新的（舊行為，重送就會變成新的一列）
            serverRows.withLock { _ = $0.insert(id) } // INSERT 已 commit
            if attempt == 1, tag == "2" { try await Task.sleep(for: .seconds(60)) } // 回應遺失
            return id
        }
        let store = UploadQueueStore(familyID: UUID(), mediaUploadService: mediaService, maxConcurrentUploads: 3)
        addTeardownBlock { @MainActor in store.discardPersistedState() }
        let uploads = (0..<3).map { makeUpload("\($0)") }

        store.enqueue(uploads)
        await waitUntil { self.completedCount(store) == 2 }
        store.appDidEnterBackground()
        store.appDidBecomeActive()
        await waitUntil { store.remainingCount == 0 }

        XCTAssertEqual(store.remainingCount, 0, "重送後 3 張都要完成")
        XCTAssertEqual(serverRows.withLock { $0.count }, 3, "回應遺失後重送不能在伺服器多出一列 media（重複照片）")
        let sentIDs = mediaService.uploadPhotoCalls.compactMap(\.mediaID)
        XCTAssertEqual(sentIDs.count, mediaService.uploadPhotoCalls.count, "每次嘗試都要指定 mediaID")
        XCTAssertEqual(Set(sentIDs), Set(uploads.map(\.id)), "mediaID 用佇列項 id，重送沿用同一個")
    }
}
