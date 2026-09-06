#if DEBUG
import AVFoundation
import SwiftUI
import UIKit

/// LS-193 R4：`diaryCardVideoBadgesHost` 這個 host 從 `TapTargetGateHarness.swift` 拆出獨立
/// 檔案——merge origin/development（LS-189）之後兩支各自沒超過 SwiftLint `file_length` 上限的
/// 檔案疊在一起變成 401 行，同其餘 `TapTargetGateHarness+*.swift` 從主檔拆分的既有理由，這裡
/// 不是新功能，純粹把既有內容原樣搬過來。非 `private`（呼叫端是主檔 `hostView(for:)` 的
/// switch 分支）；`photoTestImageURL`／`thumbnailVideoTestImageURL`／
/// `legacyVideoTestImageURL`／`makeTestImageURL(width:height:color:)` 只在這個檔案內使用，
/// 維持 `private`。
extension TapTargetGateHarness {
    /// merge-review `443ec21a` §3：`DiaryCardVideoBadgeGeometryTests` 量真實 frame 用——
    /// `timelineStore` 帶一個立即回傳固定時長（12:34，兩位數分鐘，取「分鐘數兩位會再寬」的
    /// 最壞情況，見 reviewer 原文）的 `durationLoader`，讓無縮圖列的 `.task` 一啟動就能把
    /// `videoDurations` 填成「影片 12:34」，不必等真的（會失敗的）`AVURLAsset` 探測。3 張
    /// 附照＝`totalPhotoCount`，不觸發「還有 N 張」暗蓋，3 個徽章狀態（無徽章／縮圖影片
    /// 恆「影片」／無縮圖舊影片「影片 12:34」）同時可見、可測。
    ///
    /// QA R4（`a356f033` FAIL）：三個 `MediaContent` 原本 `signedURL` 不是 `nil` 就是假的
    /// `https://example.com/...`——`AsyncImage` 永遠載不到真圖，一律落回
    /// `thumbnailImage(_:)` 的 `Color.lsSurface2`（無固有尺寸的純色，任何 `.frame` 給多寬就是
    /// 多寬，怎麼裁都不會露餡）。這正是 R2／R3 兩輪模擬器像素量測從未踩到「真圖片撐爆格子」
    /// 這個缺陷的原因——真人上傳的直式縮圖（235×512，長寬比 ~1:2.18）用
    /// `.scaledToFill()` 蓋滿正方提案時，理想尺寸遠大於那個正方形，見
    /// `DiaryCardView.previewThumbnail` 的 `.clipped()` 修復註解。改用
    /// `makeTestImageURL(width:height:color:)`（runtime 產生、寫進
    /// `FileManager.default.temporaryDirectory`，不依賴任何外部路徑或網路，CI／其他 checkout
    /// 都能重現）產生三張長寬比刻意不同、且都跟 `MediaContent` 宣告的 `width`／`height`（或
    /// `thumbWidth`／`thumbHeight`）成比例一致的**真實可解碼圖片**——橫向照片（4:3）、直式
    /// 縮圖影片（~1:2.18，QA 踩到的那個比例）、直式舊影片（~1:2.17）——`AsyncImage` 這次會
    /// 真的走 `.success` 分支，才能量到 `.clipped()` 修復是否生效。
    @MainActor
    @ViewBuilder
    static var diaryCardVideoBadgesHost: some View {
        let legacyVideoID = UUID()
        let thumbnailVideoID = UUID()
        NavigationStack {
            ScrollView {
                DiaryCardView(
                    content: DiaryContent(
                        body: "點擊目標 gate 幾何量測樣本", entryDate: Date(),
                        previewPhotos: [
                            MediaContent(
                                id: UUID(), type: .photo, width: 800, height: 600,
                                thumbWidth: nil, thumbHeight: nil, storagePath: "f/photo.jpg",
                                isThumbnail: false, signedURL: photoTestImageURL, durationSeconds: nil
                            ),
                            // LS-135：這裡刻意仍是 `durationSeconds: nil`（過渡期樣本，模擬
                            // LS-135 之前上傳、量測失敗，或 `duration_seconds` 尚未回填的縮圖
                            // 影片列）——`DiaryCardVideoBadgeGeometryTests.
                            // testThumbnailVideoBadge_singleLine_withinCardBounds_
                            // ocrMatchesPlainLabel` 斷言這一格恆顯示純文字「影片」，不觸發
                            // `loadVideoDuration`。`duration_seconds` 有值時（LS-135 之後
                            // 上傳的新影片）徽章改顯示「影片 M:SS」的行為改由
                            // `DiaryCardVideoBadgeTests`（單元測試，見該檔
                            // `thumbnailVideoWithDurationSeconds` case）與 QA 生產路徑真機
                            // 上傳驗證，不佔用這個共用 harness 場景。
                            MediaContent(
                                id: thumbnailVideoID, type: .video, width: 884, height: 1920,
                                thumbWidth: 235, thumbHeight: 512, storagePath: "f/thumb-video.mov",
                                isThumbnail: true, signedURL: thumbnailVideoTestImageURL, durationSeconds: nil
                            ),
                            MediaContent(
                                id: legacyVideoID, type: .video, width: 884, height: 1920,
                                thumbWidth: nil, thumbHeight: nil, storagePath: "f/legacy-video.mov",
                                isThumbnail: false, signedURL: legacyVideoTestImageURL, durationSeconds: nil
                            )
                        ],
                        totalPhotoCount: 3
                    ),
                    taggedChildren: [],
                    timelineStore: .preview(durationLoader: { _ in CMTime(seconds: 754, preferredTimescale: 600) }),
                    // merge-review R3（`add3f2c1` m1）：`DiaryCardView` 不再自己量寬，改由
                    // 呼叫端（正式路徑是 `TimelineView.feedContentWidth`）算好傳入——這裡比照
                    // 單欄（`columns == 1`）情境算一次同款的值（螢幕寬扣 `screenPad`＋
                    // `insetCard` 各兩份），跟 `TimelineView` 的算法一致。
                    previewRowWidth: UIScreen.main.bounds.width
                        - 2 * AppSpacing.screenPad - 2 * AppSpacing.insetCard
                )
                .padding(.horizontal, AppSpacing.screenPad)
            }
        }
    }

    /// merge-review R1（`3119a0cc` i3）：`diaryCardVideoBadgesHost` 是 `@ViewBuilder` 計算
    /// 屬性，每次 SwiftUI 重新求值 `body` 就會被重新求值一次——原本三個 `MediaContent` 都
    /// 直接呼叫 `makeTestImageURL(...)`，等於每次重繪都重新編碼一張 JPEG、寫一個帶新
    /// `UUID` 的臨時檔（只增不減），而且新檔案代表 `AsyncImage` 要重新非同步載入一次，跟
    /// i2（截圖時機可能搶在解碼前）疊加會放大測試假紅機率。改成三個 `static let`——只在
    /// 整個測試行程第一次用到時各產生一次、之後同一個 `URL` 重複使用，`AsyncImage` 對同一個
    /// `file://` URL 重繪時也不會重新觸發網路／磁碟 I/O（已有快取的圖直接進 `.success`）。
    private static let photoTestImageURL = makeTestImageURL(
        width: 200, height: 150, color: UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
    )
    private static let thumbnailVideoTestImageURL = makeTestImageURL(
        width: 118, height: 256, color: UIColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0)
    )
    private static let legacyVideoTestImageURL = makeTestImageURL(
        width: 221, height: 480, color: UIColor(red: 0.0, green: 0.8, blue: 0.2, alpha: 1.0)
    )

    /// QA R4（`a356f033`）：在 app 的 temporary directory 即時畫一張純色 JPEG、回傳
    /// `file://` URL 給 `AsyncImage` 載——不依賴 scratchpad 或任何寫死的機器路徑，同一份
    /// harness 程式碼在任何 checkout／CI runner 上都能重現同一組長寬比。純色即可：這裡要測的
    /// 是「`.scaledToFill()` 蓋滿＋裁切是否正確」，不是圖片內容本身；用不同顏色純粹方便肉眼
    /// 截圖辨識哪一格對應哪一張測試圖。
    ///
    /// merge-review R1（`3119a0cc` i3）：編碼／寫檔失敗原本用 `try?` 悄悄吞掉——這支硬體
    /// 對測試而言等於「這張圖片一直是空的」，實際症狀會是 `DiaryCardVideoBadgeGeometryTests`
    /// 報「水平掃描找不到橙色格」這種跟真正病灶（寫檔失敗）完全對不上的誤導性訊息。改成
    /// `assertionFailure`——DEBUG-only harness，失敗就應該立刻炸開讓人看到真正原因，不是
    /// 靜靜吞掉再讓下游測試用一句不相干的錯誤訊息去猜。
    private static func makeTestImageURL(width: Int, height: Int, color: UIColor) -> URL {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ls130-tap-target-gate-\(UUID().uuidString)", conformingTo: .jpeg)
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            assertionFailure("LS-130 test harness：\(width)×\(height) 測試圖 JPEG 編碼失敗")
            return url
        }
        do {
            try data.write(to: url)
        } catch {
            assertionFailure("LS-130 test harness：測試圖寫檔失敗 \(url)：\(error)")
        }
        return url
    }
}
#endif
