#if DEBUG
import AVFoundation
import os
import SwiftUI

/// LS-246 R2（dev CI run `34743983632` FAIL 修正）：`diaryDetailWithVideoHost` 這個 host 從
/// `TapTargetGateHarness+Safety.swift` 拆出獨立檔案——同其餘 `TapTargetGateHarness+*.swift`
/// 從主檔拆分的既有理由，這裡額外疊上影片合成邏輯會讓 `+Safety.swift` 逼近 SwiftLint
/// `file_length` 上限。
///
/// **R1 根因（xcresult `test-results activities` 逐行核對，非猜測）**：R1 版本 `signedURL`
/// 指向假的 `https://example.com/harness-video.mp4`——這個網域*真的能連上*（IANA 保留測試
/// 網域，回一個 HTML 頁面，不是連線失敗），`AVPlayer` 因此不是立即失敗，而是把它當成「內容
/// 存在但格式不支援」，顯示 `UnsupportedContentIndicator`。dev CI（iOS 26.2，`os.build 23C54`）
/// 上，`AVPlayerViewController` 在這個「內容不支援」狀態維持數秒之後，**自己把整個呈現關掉**
/// （`activities` 時間軸：t=120.5 點影片 → t=126.1 `UnsupportedContentIndicator` 出現
/// （符合 `signDelayNanoseconds` 3 秒＋輪詢耗時）→ t=127.2 點內容區浮現控制列 → t=130.2
/// `關閉` 鈕的 `waitForExistence(timeout: 5)` 確認存在（通過）→ t=131.2–133.3 `.tap()` 內部
/// 重新尋找元素兩次都找不到、最終在 t=133.4 回報「找不到『關閉』」，此時畫面已經是
/// `DiaryDetailView` 本體——即 `waitForExistence` 通過後、`.tap()` 真正執行前的 1–3 秒窗口內
/// `fullScreenCover` 已被系統自動收起）。本機 iOS 26.0 沒有重現（見 R2 handoff），是 iOS
/// 26.2 上 AVKit 對「內容不支援」狀態的自動收起時機差異，不是本票互斥邏輯的缺陷——mutual
/// exclusion 邏輯本身（`sheetBinding`／`videoBinding`）沒有涉入這次失敗（失敗發生在
/// `activeSheet` 已經正確等於 `.video(...)` 之後，是 AVKit 自己把呈現關掉，不是被留言
/// sheet／內容操作表搶走）。
///
/// **修法**：不再用會連上真伺服器、回傳非影片內容的網路 URL——改用 `AVAssetWriter` 在本機
/// 合成一支*真正可解碼*的最短 H.264 mp4（同 `scripts/ops/review-demo-genvideo.swift` 既有
/// 技術，那支是給 demo seed 用的獨立命令列工具，這裡是 app harness 內部需要、不能共用同一份
/// 檔案）。真正有效的影片內容讓 `AVPlayerViewController` 走正常播放路徑，不會進入
/// 「不支援」狀態、不會觸發那個自動收起行為；300 秒長度遠超過測試互動所需時間，不會播完自然
/// 結束（LS-259 第 3 項：訂正註解與 `harnessVideoURL` 實際參數 `seconds: 300, fps: 1` 對齊，
/// 原文誤寫「30 秒」且混入簡體字「长」）。
extension TapTargetGateHarness {
    /// LS-246（票文範圍 1）：同 `diaryDetailHost`，但瀑布流帶一支已經簽好名（`isPlayableVideo`
    /// 判定為可播放）的影片格——`DiaryDetailVideoUITests` 用它驗證「留言 sheet 開著時點影片」
    /// 「影片全螢幕關閉後點『⋯』」都正確併入單一 `activeSheet`（見 `DiaryDetailView` 檔頭文件
    /// 註解、`TimelineStore.preview(diaryID:video:signedURL:)`）。`durationSeconds` 直接種好
    /// （非 nil）——`TimelineStore.displayDuration` 因此不需要真的向 `signedURL` 讀
    /// `AVURLAsset`（那是另一支查表機制，不影響這裡合成的真實檔案本身能否播放），accessibility
    /// label 穩定顯示「影片 0:05，點兩下播放」，不受 `loadVideoDuration` 非同步查表時序影響。
    /// `signDelayNanoseconds` 給 3 秒——`DiaryDetailVideoUITests` 的「留言 sheet 開著時點影片」
    /// 需要在「點影片、簽名回來」之間有個穩定的窗口能再觸發留言鈕，不依賴真網路延遲的不確定
    /// 時序（見該屬性文件註解）；R1 實測：`waitForExistence`／`.tap()` 這類 XCUITest 動作本身
    /// 單次就可能耗費 1–1.5 秒（輪詢間隔＋IPC 往返），0.6 秒窗口太短，「點影片→確認留言鈕
    /// 存在→點留言鈕」這三步加起來就可能超過視窗、讓影片先接手；3 秒留足這整串動作的餘裕，
    /// UITest 端仍是用 `waitForExistence` 而非固定 sleep 等待，不會因為機器快慢而變脆弱。
    @MainActor
    static var diaryDetailWithVideoHost: some View {
        let diaryID = UUID()
        let viewerUserID = UUID()
        let familyStore = FamilyStore.preview()
        familyStore.seedMyFamilyForPreview(
            Family(id: UUID(), name: "陳家", createdBy: viewerUserID, createdAt: Date(), requireApproval: true),
            ownerUserID: viewerUserID
        )
        let timelineStore = TimelineStore.preview(
            diaryID: diaryID,
            video: MediaRow(
                id: UUID(), storagePath: "f/harness-video.mov", type: .video, width: 884, height: 1920,
                thumbPath: nil, thumbWidth: nil, thumbHeight: nil, durationSeconds: 5
            ),
            signedURL: harnessVideoURL,
            signDelayNanoseconds: 3_000_000_000
        )
        timelineStore.seedForPreview(entries: [
            TimelineEntry(
                kind: .diary, refId: diaryID, occurredAt: Date(), childIds: [],
                content: .diary(DiaryContent(
                    body: "今天在溜滑梯上玩得好開心。", entryDate: Date(), previewPhotos: [], totalPhotoCount: 1
                ))
            )
        ])
        let childrenStore = ChildrenStore.preview()
        childrenStore.seedRoleForPreview(.owner)
        return NavigationStack {
            DiaryDetailView(
                diaryID: diaryID, timelineStore: timelineStore, childrenStore: childrenStore,
                familyStore: familyStore, safetyAPIClient: PreviewSafetyAPIClient(authorID: UUID()),
                diaryAPIClient: PreviewDiaryAPIClient(), commentAPIClient: PreviewCommentAPIClient()
            )
        }
    }

    /// R1（merge-review 同款教訓，`+DiaryCardVideoBadges.swift` `photoTestImageURL` 既有先例）：
    /// `static let`——整個測試行程只合成一次，同一個 `URL` 重複使用，不會每次重繪都重新編碼。
    ///
    /// R2（手動模擬器實測）：起初給 30 秒，手動用 mobile-mcp 操作（往返延遲遠高於 XCUITest）
    /// 走完「點影片→確認控制列→點關閉」這串動作就已經量到「共經過 0:30／剩餘 -0:00」——影片
    /// 已經自然播完到底。300 秒（1fps、300 個畫格，檔案仍是毫秒等級即可合成完畢）留更大的
    /// 安全餘裕，避免慢 CI runner 上的測試互動時間逼近影片長度、再次撞見「播放器自然播完」
    /// 這一類非本票互斥邏輯的環境性風險。
    private static let harnessVideoURL = makeTestVideoURL(seconds: 300, width: 64, height: 64, fps: 1)

    /// R2：合成一支真正可解碼的最短 H.264 mp4（同 `scripts/ops/review-demo-genvideo.swift`
    /// 既有技術，那支是命令列工具、跑在獨立 process，這裡是 app 內部同步呼叫，不能共用同一份
    /// 檔案）。64×64、1 fps、300 秒（LS-259 第 3 項：訂正與 `harnessVideoURL` 實際呼叫參數
    /// 對齊，原文誤寫「2 fps、30 秒」）——解析度與 fps 壓到最低讓合成在毫秒等級完成，長度留足
    /// 測試互動所需的餘裕（遠超過任何單一 UITest 的執行時間），避免播完自然結束、被系統收起。
    ///
    /// 用 `DispatchSemaphore` 同步等待（同 `review-demo-genvideo.swift` 既有作法）：這裡是
    /// DEBUG-only harness 的一次性初始化，不是生產路徑的效能敏感區。任何一步失敗都
    /// `assertionFailure`（DEBUG-only 立即炸開）而不是靜默回傳一個不完整的檔案——那會讓下游
    /// UITest 報一個跟真正病灶（合成失敗）完全對不上的誤導性訊息（同 `makeTestImageURL`
    /// 既有理由）。
    private static func makeTestVideoURL(seconds: Double, width: Int, height: Int, fps: Int32) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ls246-tap-target-gate-video-\(UUID().uuidString)", conformingTo: .mpeg4Movie)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            assertionFailure("LS-246 test harness：AVAssetWriter 建立失敗")
            return url
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            assertionFailure("LS-246 test harness：startWriting 失敗：\(writer.error?.localizedDescription ?? "unknown")")
            return url
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(2, Int(seconds * Double(fps)))
        // `requestMediaDataWhenReady(on:)` 的 handler 是 `@Sendable`——同 `AlbumsStoreAttach
        // UploadedMediaTests` 既有作法，計數器包一層鎖而不是裸 `var` 捕捉（handler 實際上永遠
        // 排在同一個序列 `queue` 上執行，鎖只是滿足編譯期資料競爭檢查，不是真的有併發）。
        let frameCounter = OSAllocatedUnfairLock(initialState: 0)
        let queue = DispatchQueue(label: "LS246.harnessVideo")
        let done = DispatchSemaphore(value: 0)
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                let frame = frameCounter.withLock { $0 }
                if frame >= frameCount {
                    input.markAsFinished()
                    writer.finishWriting { Self.assertFinishedWriting(writer, done: done) }
                    return
                }
                guard Self.appendFrame(frame, to: adaptor, height: height, fps: fps, writer: writer) else {
                    done.signal()
                    return
                }
                frameCounter.withLock { $0 += 1 }
            }
        }
        if done.wait(timeout: .now() + 20) == .timedOut {
            assertionFailure("LS-246 test harness：影片合成逾時（20 秒）")
        }
        return url
    }

    /// LS-259 第 2 項（merge-review R1 m1，`82724334`）：`finishWriting` 的 completion 只
    /// signal，沒檢查 `writer.status`——合成若在這個階段才失敗（早於此的 `startWriting`／
    /// `adaptor.append` guard 都沒攔到），會靜默把 `url` 交給呼叫端，下游
    /// `AVPlayerViewController` 播放不了一支不完整的檔案，錯誤訊息離真正病灶（合成失敗）很遠。
    /// 明確失敗優於假綠（同 `appendFrame` 既有理由）。抽出成獨立函式單純是為了不讓
    /// `makeTestVideoURL` 超過 SwiftLint `function_body_length`，邏輯未變。
    private static func assertFinishedWriting(_ writer: AVAssetWriter, done: DispatchSemaphore) {
        guard writer.status == .completed else {
            preconditionFailure(
                "LS-259 test harness：finishWriting 後 status 非 .completed（\(writer.status.rawValue)）："
                    + "\(writer.error?.localizedDescription ?? "unknown")"
            )
        }
        done.signal()
    }

    /// `makeTestVideoURL` 逐格寫入抽出的一步——純色畫格，內容本身不重要（同 `makeTestImageURL`
    /// 既有理由，這裡要測的是「真的能被 `AVPlayerViewController` 解碼播放」，不是畫面內容）。
    /// 失敗時 `assertionFailure` 並回傳 `false`，呼叫端據此結束整段合成——不留一份不完整的
    /// 檔案讓下游 UITest 報一個跟真正病灶（合成失敗）對不上的誤導性訊息。
    private static func appendFrame(
        _ frame: Int, to adaptor: AVAssetWriterInputPixelBufferAdaptor, height: Int, fps: Int32, writer: AVAssetWriter
    ) -> Bool {
        guard let pool = adaptor.pixelBufferPool else {
            assertionFailure("LS-246 test harness：pixelBufferPool 為 nil（frame \(frame)）")
            return false
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            assertionFailure("LS-246 test harness：CVPixelBufferPoolCreatePixelBuffer 失敗（frame \(frame)）")
            return false
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ptr = CVPixelBufferGetBaseAddress(buffer) {
            memset(ptr, 120, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTimeMake(value: Int64(frame), timescale: fps)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            let message = writer.error?.localizedDescription ?? "unknown"
            assertionFailure("LS-246 test harness：adaptor.append 失敗（frame \(frame)）：\(message)")
            return false
        }
        return true
    }
}
#endif
